# Where the CloudWatch agent (build/ami/install.sh) ships codedeploy-agent's
# log, /var/log/gramps-deploy.log, and cloud-init's two logs -- the only
# instance-side visibility into what happened during a launch that never
# reaches app-level health checks (a hung CodeDeploy Install, a stuck
# cloud-init). One group, not four: the four log_stream_name values (set in
# the agent config) already disambiguate by source and instance ID.
resource "aws_cloudwatch_log_group" "instance" {
  name              = "/gramps-web/instance"
  retention_in_days = 30

  tags = {
    Name = "gramps-web-instance"
  }
}
