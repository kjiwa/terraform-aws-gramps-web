resource "random_password" "flask_secret" {
  length  = 64
  special = false
}

resource "aws_ssm_parameter" "flask_secret" {
  name        = "/gramps-web/${var.env}/flask-secret"
  description = "Flask SECRET_KEY for Gramps Web. Generated once; ignore_changes prevents rotation."
  type        = "SecureString"
  value       = random_password.flask_secret.result

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name = "gramps-web-flask-secret"
  }
}

# Gramps Web's frontend runtime config (window.grampsjsConfig -- see the root
# frontend variable in variables.tf for the full
# option-by-option rationale). Built by merging conditional single-key maps
# so an unset option is *absent* from config.js rather than present with a
# zero/empty value -- upstream's own default only takes effect when the key
# is missing entirely. jsonencode below does all the JSON escaping; nothing
# here does string concatenation. hideRegisterLink comes from api.registration
# alone -- upstream treats registration-disabled and link-hidden as two
# separately scoped settings, but this stack has one tree and one frontend, so
# the two always move together and a single mode decides both.
locals {
  frontend_config = merge(
    var.frontend.hide_dna_link ? { hideDNALink = true } : {},
    var.api.registration == "open" ? {} : { hideRegisterLink = true },
    var.frontend.login_redirect == "" ? {} : { loginRedirect = var.frontend.login_redirect },
    var.frontend.map_base_style_light == "" ? {} : { mapBaseStyleLight = var.frontend.map_base_style_light },
    var.frontend.map_base_style_dark == "" ? {} : { mapBaseStyleDark = var.frontend.map_base_style_dark },
    var.frontend.map_ohm_style == "" ? {} : { mapOhmStyle = var.frontend.map_ohm_style },
  )
}

# Whole frontend runtime config, authored here rather than by the shell so
# jsonencode does all quoting/escaping -- build/app/bundle/scripts/
# after_install.sh fetches this parameter straight to /app/static/config.js
# with no parsing or validation on its end. Its name reaches the instance as
# SSM_FRONTEND_CONFIG_PARAM in instance.env (launch_template.tf), a resource
# reference rather than a derivation, so a rename here needs no matching shell
# change. Kept as a sibling of gramps-env's path below (both under
# /gramps-web/${var.env}/) by convention regardless -- see the launch
# template's precondition.
resource "aws_ssm_parameter" "frontend_config" {
  name        = "/gramps-web/${var.env}/frontend-config"
  description = "Whole window.grampsjsConfig object, as a ready-to-use JS assignment statement, consumed by the CodeDeploy after_install hook and written verbatim to /app/static/config.js."
  type        = "String"
  value       = "window.grampsjsConfig = ${jsonencode(local.frontend_config)}"

  tags = {
    Name = "gramps-web-frontend-config"
  }
}

# Every Gramps Web API setting this stack sets, as one non-secret KEY=value
# table -- upstream's own keys, unprefixed, exactly as they'd appear in
# config.cfg. null means "leave unset" (upstream's own default applies);
# every optional field in var.api/var.llm defaults to null for exactly this
# reason. Secrets (SECRET_KEY, EMAIL_HOST_PASSWORD) are deliberately NOT here
# -- they're SecureStrings fetched individually and written straight to
# secrets.env by the CodeDeploy after_install hook (see docker-compose.yml
# and after_install.sh), never touching a plain String parameter.
locals {
  gramps_env = merge(
    {
      TREE                              = var.api.tree
      TREE_ID                           = var.api.tree_id
      BASE_URL                          = var.base_url
      MEDIA_BASE_DIR                    = "s3://${var.media_bucket_name}"
      EMAIL_HOST                        = var.smtp.host
      EMAIL_PORT                        = var.smtp.port
      EMAIL_USE_STARTTLS                = var.smtp.use_starttls
      EMAIL_HOST_USER                   = var.smtp.username
      DEFAULT_FROM_EMAIL                = var.smtp.from_address
      REGISTRATION_DISABLED             = var.api.registration == "closed"
      DISABLE_TELEMETRY                 = var.api.disable_telemetry
      PILLOW_MAX_IMAGE_PIXELS           = var.api.pillow_max_image_pixels
      MAX_THUMBNAIL_FILE_BYTES          = var.api.max_thumbnail_file_bytes
      LOG_LEVEL                         = var.api.log_level
      RATE_LIMIT_MEDIA_ARCHIVE          = var.api.rate_limit_media_archive
      CORS_ORIGINS                      = var.api.cors_origins
      CELERY_CONFIG__broker_url         = "redis://valkey:6379/0"
      CELERY_CONFIG__result_backend     = "redis://valkey:6379/0"
      RATELIMIT_STORAGE_URI             = "redis://valkey:6379/1"
      THUMBNAIL_CACHE_CONFIG__CACHE_DIR = "/app/cache/thumbnail_cache" # EBS-backed cache dir so thumbnails survive deploys and Spot reclaims.
    },
    var.llm.enabled ? {
      LLM_MODEL              = "bedrock:${var.llm.model_id}"
      LLM_MAX_REQUESTS       = var.llm.max_requests
      LLM_MAX_TOKENS         = var.llm.max_tokens
      LLM_MAX_CONTEXT_LENGTH = var.llm.max_context_length
      LLM_SYSTEM_PROMPT      = var.llm.system_prompt != "" ? var.llm.system_prompt : null
    } : {},
    # In-app stored backups need a directory that survives Spot reclaims: the
    # EBS data volume.
    {
      BACKUP_DIR = "/app/backups"
    },
    var.api.extra,
  )
}

# Read by build/app/bundle/scripts/origin_cert.sh, which derives this name as a
# sibling of the gramps-env parameter. The ARN comes from modules/edge, whose
# validation resource gates this parameter on the certificate being issued.
resource "aws_ssm_parameter" "origin_certificate_arn" {
  name        = "/gramps-web/${var.env}/origin-certificate-arn"
  description = "ARN of the exportable ACM certificate the instance serves TLS with, consumed by the origin_cert.sh deploy-time export."
  type        = "String"
  value       = var.origin_certificate_arn

  tags = {
    Name = "gramps-web-origin-certificate-arn"
  }
}

# Runtime-only knobs read by the AMI-baked watchdog timers (build/ami/
# health-watchdog.sh, rightsize-watchdog.sh) via load_runtime_env() in
# /usr/local/lib/gramps-runtime.sh. Split out of instance.env so that flipping
# one of these doesn't render a new launch template and force an instance
# refresh -- the watchdogs pick the change up on their own poll instead.
# Ready-to-source KEY=value lines, same verbatim-fetch contract as gramps_env.
resource "aws_ssm_parameter" "instance_runtime" {
  name        = "/gramps-web/${var.env}/instance-runtime"
  description = "Runtime-only instance config (STATUS_HOST_METRICS, STATUS_VOLUME_METRICS, RIGHTSIZE_MIN_UPTIME_HOURS), as ready-to-source KEY=value lines, polled by the AMI-baked watchdog timers. Changing it never touches the launch template or forces an instance replacement."
  type        = "String"
  value = join("\n", [
    "STATUS_HOST_METRICS=${var.status_host_metrics}",
    "STATUS_VOLUME_METRICS=${var.status_volume_metrics}",
    "RIGHTSIZE_MIN_UPTIME_HOURS=${var.rightsize_min_uptime_hours}",
  ])

  tags = {
    Name = "gramps-web-instance-runtime"
  }
}

resource "aws_ssm_parameter" "gramps_env" {
  name        = "/gramps-web/${var.env}/gramps-env"
  description = "Non-secret Gramps Web API env (GRAMPSWEB_* KEY=value lines, upstream keys), consumed by the CodeDeploy after_install hook via docker compose's env_file:."
  type        = "String"
  value = join("\n", concat(
    ["# rendered by terraform from var.api / var.llm; do not edit"],
    [for k in sort(keys(local.gramps_env)) : "GRAMPSWEB_${k}=${jsonencode(local.gramps_env[k])}" if local.gramps_env[k] != null],
  ))

  tags = {
    Name = "gramps-web-env"
  }
}
