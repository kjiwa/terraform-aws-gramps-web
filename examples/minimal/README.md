# Minimal deployment

Hosted zone, cost budget, and audit trail from [terraform-aws-keel](https://github.com/kjiwa/terraform-aws-keel), plus Gramps Web with two required inputs and your fork (`repo_url`, `source_branch`; see the root README's Quickstart).

```hcl
module "gramps_web" {
  source        = "git::https://github.com/kjiwa/terraform-aws-gramps-web.git?ref=v1.1.0"
  repo_url      = "https://github.com/<you>/terraform-aws-gramps-web"
  source_branch = "release-1.1"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  primary_domain = "example.org"
  alert_email    = "you@example.org"

  depends_on = [module.dns]
}
```

The module needs an `aws.us_east_1` provider alias and a public Route 53 hosted zone for each domain. `main.tf` creates the zone with keel's `dns` module.
