variable "env" {
  description = "Environment name. Disambiguates the SMTP password SSM parameter path."
  type        = string
}

variable "primary_domain" {
  description = "Domain to verify as an SES sending identity. From-address and MAIL FROM are derived from it."
  type        = string
}

variable "zone_ids" {
  description = "Map of domain name to Route53 zone ID (from the dns module). Must contain primary_domain."
  type        = map(string)
}

variable "from_local_part" {
  description = "Local part of the default From address (e.g. 'no-reply' -> no-reply@<primary_domain>)."
  type        = string
  default     = "no-reply"
}

variable "mail_from_subdomain" {
  description = "Subdomain label for the custom MAIL FROM domain (e.g. 'mail' -> mail.<primary_domain>). Gives SPF alignment."
  type        = string
  default     = "mail"
}

variable "dmarc_rua" {
  description = "Optional mailto: URI for DMARC aggregate reports. Empty string omits the rua tag."
  type        = string
  default     = ""
}
