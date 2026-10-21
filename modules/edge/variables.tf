variable "env" {
  description = "Environment name. Used only to namespace the /gramps-web/<env>/* SSM path this module publishes the primary distribution ID under (ssm.tf) -- the same path the compute module's instance role already reads from, so the app deploy hook can discover the distribution ID without a direct Terraform reference into this module (see ssm.tf's comment for why that reference would be a dependency cycle)."
  type        = string
}

variable "primary_domain" {
  description = "Apex domain serving the site (e.g. example.org)."
  type        = string
}

variable "redirect_domains" {
  description = "Set of apex domains that 301 to the primary."
  type        = set(string)
}

variable "eip_public_ip" {
  description = "EIP address of the EC2 origin. Target of the origin.<primary_domain> A record in route53_records.tf; CloudFront's origin domain_name is that hostname, never the bare IP."
  type        = string
}

variable "zone_ids" {
  description = "Map of domain name to Route53 zone ID. Must cover primary and all redirect domains."
  type        = map(string)
}

variable "additional_origins" {
  description = "Extra CloudFront origins on the primary distribution, keyed by origin ID, for serving content beside the app. domain_name is the origin hostname (for S3, the bucket regional domain name); origin_access_control_id is optional. Referenced by additional_cache_behaviors. The caller owns the origin's access policy; scope it to the primary_distribution_arn output."
  type = map(object({
    domain_name              = string
    origin_access_control_id = optional(string)
  }))
  default = {}
}

variable "additional_cache_behaviors" {
  description = "Extra ordered cache behaviors on the primary distribution, matched in list order before the status behaviors and so must not overlap /_errors/*, /_status*, or the static-asset patterns. target_origin_id names an additional_origins key. Defaults serve GET and HEAD with the managed CachingOptimized policy and no origin request policy (forwarding Host to an OAC origin breaks SigV4); function_associations attaches CloudFront functions (event_type, function_arn). Behaviors are HTTPS-only and compressed."
  type = list(object({
    path_pattern             = string
    target_origin_id         = string
    allowed_methods          = optional(list(string), ["GET", "HEAD"])
    cache_policy_id          = optional(string, "658327ea-f89d-4fab-a63d-7e88639e58f6")
    origin_request_policy_id = optional(string)
    function_associations = optional(list(object({
      event_type   = string
      function_arn = string
    })), [])
  }))
  default = []
}

variable "status_enabled" {
  description = "If true, provision the authenticated /_status operational status page: its OAC, origin request policy, Lambda permissions, and the /_status origin + behaviors on the primary distribution. If false none of those exist and /_status* falls through to the app origin. The Lambda itself lives in modules/status, applied by the root alongside this module."
  type        = bool
}

variable "status_function_name" {
  description = "Name of the status Lambda (modules/status). Named here so aws_lambda_permission can grant CloudFront's OAC invoke rights on it; ignored when status_enabled is false."
  type        = string
}

variable "status_function_url" {
  description = "Function URL of the status Lambda (modules/status), e.g. https://<id>.lambda-url.<region>.on.aws/. The scheme and trailing slash are stripped locally to get the bare hostname CloudFront's origin domain_name requires; ignored when status_enabled is false."
  type        = string
}

variable "status_public_reliability" {
  description = "If true (and status_enabled), also provision the /_status/public CloudFront behavior: CachingOptimized, no origin request policy (no client headers reach it, so X-Gramps-Token can never land on a cached response). If false, the behavior doesn't exist at all, so the request falls through to the app (EC2) origin and 404s there, never reaching the status Lambda. See public_reliability in the status variable, terraform/roots/stack/variables.tf, for the full feature description."
  type        = bool
}

variable "status_disabled_panels" {
  description = "Panel keys (backups, assistant, cost, host_metrics) the static status shell should hide before its first data fetch resolves, matching status.py's own data-panel keys. Written into aws_s3_object.status_config's config.js (status_assets.tf); ignored when status_enabled is false."
  type        = list(string)
}
