output "name_servers" {
  description = "Name servers to set at the registrar for the domain (map of domain to list)."
  value       = module.dns.ns_records
}

output "status_url" {
  description = "Status page URL, or null when the status page is off."
  value       = module.gramps_web.status_url
}

output "gramps_web" {
  description = "The module's outputs, as one object. The operator scripts under scripts/ read it with `terraform output -json`; pass this directory as --root."
  value       = module.gramps_web
}
