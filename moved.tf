# Status resources that moved out of module.edge (count-indexed there) into
# the core status module, which has no count.

moved {
  from = module.edge.aws_cloudfront_origin_access_control.status[0]
  to   = module.status[0].module.core.aws_cloudfront_origin_access_control.status
}

moved {
  from = module.edge.aws_cloudfront_origin_request_policy.status[0]
  to   = module.status[0].module.core.aws_cloudfront_origin_request_policy.status
}

moved {
  from = module.edge.aws_lambda_permission.status[0]
  to   = module.status[0].module.core.aws_lambda_permission.status
}

moved {
  from = module.edge.aws_lambda_permission.status_invoke_function[0]
  to   = module.status[0].module.core.aws_lambda_permission.status_invoke_function
}

moved {
  from = module.edge.aws_s3_bucket.status_assets[0]
  to   = module.status[0].module.core.aws_s3_bucket.status_assets
}

moved {
  from = module.edge.aws_s3_bucket_public_access_block.status_assets[0]
  to   = module.status[0].module.core.aws_s3_bucket_public_access_block.status_assets
}

moved {
  from = module.edge.aws_cloudfront_origin_access_control.status_assets[0]
  to   = module.status[0].module.core.aws_cloudfront_origin_access_control.status_assets
}

moved {
  from = module.edge.aws_s3_bucket_policy.status_assets[0]
  to   = module.status[0].module.core.aws_s3_bucket_policy.status_assets
}

moved {
  from = module.edge.aws_cloudfront_function.status_rewrite[0]
  to   = module.status[0].module.core.aws_cloudfront_function.status_rewrite
}

moved {
  from = module.edge.aws_s3_object.status_config[0]
  to   = module.status[0].module.core.aws_s3_object.status_config
}
