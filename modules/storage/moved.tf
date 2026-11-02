moved {
  from = aws_kms_key.data
  to   = module.data_volume.aws_kms_key.data
}

moved {
  from = aws_kms_alias.data
  to   = module.data_volume.aws_kms_alias.data
}

moved {
  from = aws_ebs_volume.this
  to   = module.data_volume.aws_ebs_volume.this
}

moved {
  from = aws_kms_key.backup
  to   = module.data_volume.aws_kms_key.backup
}

moved {
  from = aws_kms_alias.backup
  to   = module.data_volume.aws_kms_alias.backup
}

moved {
  from = aws_backup_vault.this
  to   = module.data_volume.aws_backup_vault.this
}

moved {
  from = aws_backup_vault_policy.this
  to   = module.data_volume.aws_backup_vault_policy.this
}

moved {
  from = aws_kms_key.backup_replica
  to   = module.data_volume.aws_kms_key.backup_replica
}

moved {
  from = aws_kms_alias.backup_replica
  to   = module.data_volume.aws_kms_alias.backup_replica
}

moved {
  from = aws_backup_vault.replica
  to   = module.data_volume.aws_backup_vault.replica
}

moved {
  from = aws_iam_role.backup
  to   = module.data_volume.aws_iam_role.backup
}

moved {
  from = aws_iam_role_policy_attachment.backup
  to   = module.data_volume.aws_iam_role_policy_attachment.backup
}

moved {
  from = aws_backup_plan.this
  to   = module.data_volume.aws_backup_plan.this
}

moved {
  from = aws_backup_selection.this
  to   = module.data_volume.aws_backup_selection.this
}
