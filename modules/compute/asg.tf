locals {
  # The derived memory floor is 4 GiB whether or not the AI assistant is on.
  # Measured peak use is about 1.6 GiB, 42% of a 4 GiB host; the process count
  # is the same with the assistant off. A 2 GiB host would have little
  # headroom and no swap.
  #
  # Nitro-only is a hard constraint of this module: user_data discovers the
  # data volume by NVMe controller serial, and the launch template sets
  # ebs_optimized = true -- Xen types fail both. It is enforced by excluding
  # the Xen families, a closed set (AWS builds no new Xen types), so new
  # Nitro types become eligible without editing a list. a1 is excluded too:
  # AL2023 requires Graviton2 or later. The rightsize watchdog, not this
  # spec, prefers the cheapest eligible pool.
  excluded_types = [for f in [
    "t1", "t2", "m1", "m2", "m3", "m4", "c1", "c3", "c4", "r3", "r4",
    "i2", "i3", "d2", "h1", "x1", "x1e", "g2", "g3", "p2", "p3", "a1",
  ] : "${f}.*"]

  pinned = var.instance_requirements != null

  # An empty allow-list means no allow-list: the arch is then bounded by the
  # accelerator cap and the Nitro exclusion instead of by named types.
  allowed_arm64  = local.pinned ? (length(var.instance_requirements.allowed_types_arm64) > 0 ? var.instance_requirements.allowed_types_arm64 : null) : null
  allowed_x86_64 = local.pinned ? (length(var.instance_requirements.allowed_types_x86_64) > 0 ? var.instance_requirements.allowed_types_x86_64 : null) : null

  instance_requirements = {
    vcpu_min       = local.pinned ? var.instance_requirements.vcpu_min : 2
    vcpu_max       = local.pinned ? var.instance_requirements.vcpu_max : 2
    memory_mib_min = local.pinned ? var.instance_requirements.memory_mib_min : 4096
  }
}

resource "aws_autoscaling_group" "this" {
  name = "gramps-web"

  # Never launch an instance before the instance role's policy is current.
  # Terraform infers no edge here on its own: the launch template references the
  # instance PROFILE, and the inline policy hangs off the role separately, so
  # nothing stops the two from applying in parallel.
  #
  # This is load-bearing during a volume swap (docs/az-move.md, and the re-key in
  # docs/cross-account-backup.md), where the policy's AttachVolume is scoped to
  # the volume ARN and the volume ARN has just changed. The trap is that the
  # procedure zeroes the ASG out of band while Terraform owns desired_capacity,
  # so the apply that updates the policy is ALSO the apply that scales back up --
  # "apply before scaling up" is not a thing an operator can do by sequencing.
  # Win that race and an instance boots against a policy naming the OLD volume,
  # is denied the attach, and CodeDeploy fails BeforeInstall waiting for boot
  # glue user-data never wrote. Terraform usually wins it because IAM is fast;
  # an apply that dies partway does not.
  depends_on = [aws_iam_role_policy.instance]

  # var.active is the sleep switch: 0 releases the instance while every other
  # resource (data volume, EIP, ECR image, last CodeDeploy revision) stays put,
  # so flipping back to 1 self-heals to a serving site in ~5 minutes.
  min_size            = var.active ? 1 : 0
  max_size            = var.active ? 1 : 0
  desired_capacity    = var.active ? 1 : 0
  vpc_zone_identifier = var.subnet_ids
  capacity_rebalance  = false

  mixed_instances_policy {
    launch_template {
      # Base spec is required; both overrides set their own LT explicitly, so
      # this default is only a fallback. Pointed at arm64, the cheaper pools.
      launch_template_specification {
        launch_template_id = aws_launch_template.this["arm64"].id
        version            = aws_launch_template.this["arm64"].latest_version
      }

      # arm64 / Graviton. cpu_manufacturers pins the arch; the matching arm64
      # AMI comes via this override's own launch template.
      override {
        launch_template_specification {
          launch_template_id = aws_launch_template.this["arm64"].id
          version            = aws_launch_template.this["arm64"].latest_version
        }
        instance_requirements {
          memory_mib {
            min = local.instance_requirements.memory_mib_min
          }
          vcpu_count {
            min = local.instance_requirements.vcpu_min
            max = local.instance_requirements.vcpu_max
          }
          dynamic "accelerator_count" {
            for_each = local.allowed_arm64 == null ? [1] : []
            content {
              max = 0
            }
          }
          cpu_manufacturers       = ["amazon-web-services"]
          allowed_instance_types  = local.allowed_arm64
          excluded_instance_types = local.allowed_arm64 == null ? local.excluded_types : null
          burstable_performance   = "included"
        }
      }

      # x86_64 / Intel + AMD. Same vCPU/memory floor and eligibility rule as
      # arm64 so a Spot fallout onto x86 lands on an equivalent box, not a
      # pricier one. Adds pools to ride out arm64 Spot stockouts.
      override {
        launch_template_specification {
          launch_template_id = aws_launch_template.this["x86_64"].id
          version            = aws_launch_template.this["x86_64"].latest_version
        }
        instance_requirements {
          memory_mib {
            min = local.instance_requirements.memory_mib_min
          }
          vcpu_count {
            min = local.instance_requirements.vcpu_min
            max = local.instance_requirements.vcpu_max
          }
          dynamic "accelerator_count" {
            for_each = local.allowed_x86_64 == null ? [1] : []
            content {
              max = 0
            }
          }
          cpu_manufacturers       = ["intel", "amd"]
          allowed_instance_types  = local.allowed_x86_64
          excluded_instance_types = local.allowed_x86_64 == null ? local.excluded_types : null
          burstable_performance   = "included"
        }
      }
    }

    instances_distribution {
      spot_allocation_strategy = var.spot_allocation_strategy
      # The API rejects any nonzero pool count outside lowest-price, and the
      # provider keeps the server's default of 2 in state, so switching away
      # from lowest-price fails unless this is set to 0 explicitly.
      spot_instance_pools                      = var.spot_allocation_strategy == "lowest-price" ? 2 : 0
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = var.spot_enabled ? 0 : 100
    }
  }

  # These propagated tags are the only place Name/Project land on the
  # instance; compute/iam.tf's EBSAttachDetach/
  # EIPAssociate conditions key on the Project tag actually being there, so
  # don't drop it.
  tag {
    key                 = "Name"
    value               = "gramps-web"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = "gramps-web"
    propagate_at_launch = true
  }

  # min_healthy_percentage = 0 is deliberate at size 1: the only instance must
  # come down before its replacement launches, so some downtime is inherent
  # and expected, not a fault to guard against. What alarm_specification
  # guards against is a refresh that never comes back -- without it a launch
  # stuck behind a hung CodeDeploy lifecycle hook still reports Successful. The alarm
  # is var.pathological_refresh_alarm_names, not the site's own
  # gramps-web-site-down: that one fires at 2 min of downtime, which every
  # normal size-1 refresh (3-5 min down by construction) would trip.
  #
  # No auto_rollback: AWS rejects a DesiredConfiguration -- which
  # AutoRollback requires -- on any ASG whose mixed_instances_policy override
  # uses instance_requirements, as this one does. A stuck refresh still reports Failed
  # via the alarm; it just isn't reverted automatically.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0
      alarm_specification {
        alarms = var.pathological_refresh_alarm_names
      }
    }
  }
}
