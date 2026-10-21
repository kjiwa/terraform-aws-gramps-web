# Partial backend configuration: one root serves every environment, so the
# bucket/key/region live in each env's backend.hcl and arrive at init time
# (scripts/tf.sh <env> init). Backend blocks cannot read variables; the
# per-env .hcl file is the least-duplication substitute.
# Deliberately no encrypt/kms_key_id: the bootstrap bucket encrypts state under
# its own CMK by default, so an explicit setting here would only duplicate a key
# ARN that has to be kept in sync by hand -- and `encrypt` without `kms_key_id`
# would request SSE-S3 and override that default. Same omission bootstrap and
# backup-account make, for the same reason.
terraform {
  backend "s3" {}
}
