# Cause-attribution markers written just before a deliberate act: by the
# instance to ITSELF (see build/ami/rightsize-watchdog.sh's replace_instance()
# and build/ami/health-watchdog.sh's set_unhealthy()), and by the operator for
# last_backup_snapshot (scripts/backup.sh): {"time": ..., "instance_id":
# ...}. Standard parameters = free. Seeded to "{}" and then the writer owns
# the value after creation -- same reasoning as aws_ssm_parameter.state in
# modules/monitoring/lambda.tf, whose availability Lambda reads these back to
# attribute the outage each watchdog causes.
resource "aws_ssm_parameter" "last_rightsize" {
  name  = "/gramps-web/${var.env}/last-rightsize"
  type  = "String"
  value = "{}"

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name = "gramps-web-last-rightsize"
  }
}

resource "aws_ssm_parameter" "last_health_watchdog" {
  name  = "/gramps-web/${var.env}/last-health-watchdog"
  type  = "String"
  value = "{}"

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name = "gramps-web-last-health-watchdog"
  }
}

# Written by scripts/backup.sh snapshot, from the operator's own credentials,
# just before it stops the app for a quiesced snapshot: {"time": ...,
# "instance_id": ...}. Same ownership and read-back as the markers above.
resource "aws_ssm_parameter" "last_backup_snapshot" {
  name  = "/gramps-web/${var.env}/last-backup-snapshot"
  type  = "String"
  value = "{}"

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name = "gramps-web-last-backup-snapshot"
  }
}
