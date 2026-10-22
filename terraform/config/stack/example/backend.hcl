# State location for this env, passed to `terraform init` by scripts/tf.sh.
# The bucket comes from terraform/roots/bootstrap, run once per AWS account: with
# one account per env, each env gets its own bucket in its own account (envs
# that do share an account share the bucket, each under its own key). Do not
# point one env at another env's account's bucket -- that cross-account
# access exposes the other env's state. Backend blocks cannot read
# variables, so these values live here rather than in tfvars.
# Deliberately no encrypt/kms_key_id -- see backend.tf. The bucket bootstrap
# creates encrypts state under its own CMK by default; nothing to fill in here.
bucket       = "your-tfstate-bucket"
key          = "gramps-web/example/terraform.tfstate"
region       = "us-east-2"
use_lockfile = true
