# Status Lambda Function URL, fronted here via CloudFront OAC -- the same
# access-control shape as the error pages, applied to a
# compute origin instead of S3. See the `status` variable in
# roots/stack/variables.tf for what the page shows and who can see it. Gated
# on var.status_enabled: off means none of this exists and every /_status*
# path falls through to the app origin like any other unrouted path. The six
# exact behaviors that route the on case (shell, config, data, public,
# series) live in cloudfront_primary.tf, not here -- this file is the
# OAC/permission plumbing they attach to.

resource "aws_cloudfront_origin_access_control" "status" {
  count = var.status_enabled ? 1 : 0

  name                              = "gramps-web-status"
  description                       = "OAC for the status page Lambda Function URL"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Forwards only X-Gramps-Token -- the caller's Gramps Web bearer token,
# carried outside Authorization because CloudFront overwrites Authorization
# with its own SigV4 signature when OAC-signing this request to the Lambda
# Function URL (see lambda/status.py for the full reasoning). No cookies:
# the managed AllViewer policy used on the default behavior forwards Host
# along with everything else, which breaks OAC's SigV4 signature on an
# OAC/Lambda origin exactly like it would on an OAC/S3 origin (the same trap
# noted for the error-page origin in this module). Query strings
# are whitelisted to exactly panel/range/end -- /_status/series' own
# parameters -- rather than left at "none": /_status/data sends no query
# string, so it is unaffected either way.
resource "aws_cloudfront_origin_request_policy" "status" {
  count = var.status_enabled ? 1 : 0

  name    = "gramps-web-status"
  comment = "Forward X-Gramps-Token and /_status/series' panel/range/end query params to the status Lambda"

  headers_config {
    header_behavior = "whitelist"
    headers {
      items = ["X-Gramps-Token"]
    }
  }

  cookies_config {
    cookie_behavior = "none"
  }

  query_strings_config {
    query_string_behavior = "whitelist"
    query_strings {
      items = ["panel", "range", "end"]
    }
  }
}

# Lambda Function URLs invoked via CloudFront OAC are authorized with
# lambda:InvokeFunctionUrl (not lambda:InvokeFunction, the schedule/event
# permission shape used elsewhere in this repo). The status Lambda itself is
# defined in modules/status; var.status_function_name is how its name crosses
# the module boundary to be named here.
resource "aws_lambda_permission" "status" {
  count = var.status_enabled ? 1 : 0

  statement_id           = "AllowCloudFrontServicePrincipal"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = var.status_function_name
  principal              = "cloudfront.amazonaws.com"
  source_arn             = aws_cloudfront_distribution.primary.arn
  function_url_auth_type = "AWS_IAM"
}

# Since October 2025, AWS also requires a plain lambda:InvokeFunction grant
# alongside InvokeFunctionUrl above for CloudFront's OAC-signed request to
# succeed -- without it, CloudFront's request is rejected with a 403 before
# the function ever runs (no invocation, no log entry -- indistinguishable
# from a misconfigured OAC/origin from the outside). See AWS's "Restrict
# access to a Lambda function URL origin" doc, "Grant CloudFront permission"
# step, which now lists both grants.
resource "aws_lambda_permission" "status_invoke_function" {
  count = var.status_enabled ? 1 : 0

  statement_id  = "AllowCloudFrontServicePrincipalInvokeFunction"
  action        = "lambda:InvokeFunction"
  function_name = var.status_function_name
  principal     = "cloudfront.amazonaws.com"
  source_arn    = aws_cloudfront_distribution.primary.arn
}
