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

variable "status_origins" {
  description = "Origins of the status page (modules/status origins output), attached to the primary distribution. An origin with custom_origin gets an HTTPS-only custom origin config, since Function URLs are HTTPS-only."
  type = list(object({
    origin_id                = string
    domain_name              = string
    origin_access_control_id = string
    custom_origin            = bool
  }))
  default = []
}

variable "status_behaviors" {
  description = "Ordered cache behaviors of the status page (modules/status behaviors output), placed after additional_cache_behaviors. Each serves GET, HEAD and OPTIONS over HTTPS, compressed; function_arn attaches a viewer-request function when rewrite is true. Exact path patterns, never a wildcard: first match wins."
  type = list(object({
    path_pattern             = string
    origin_id                = string
    cache_policy_id          = string
    origin_request_policy_id = string
    function_arn             = string
    rewrite                  = bool
  }))
  default = []
}
