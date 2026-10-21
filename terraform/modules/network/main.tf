data "aws_ec2_managed_prefix_list" "cloudfront_origin" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/24"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "gramps-web"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.0.0/26"
  availability_zone       = var.az
  map_public_ip_on_launch = true

  tags = {
    Name = "gramps-web-public"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "gramps-web"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "gramps-web-public"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "origin" {
  name        = "gramps-web-origin"
  description = "EC2 origin: HTTP from CloudFront origin-facing prefix list only."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "gramps-web-origin"
  }
}

# Port 80 only: the CloudFront custom origin config for this EC2 origin uses
# origin_protocol_policy = "http-only" (modules/edge/cloudfront_primary.tf).
resource "aws_vpc_security_group_ingress_rule" "origin_http_from_cloudfront" {
  security_group_id = aws_security_group.origin.id
  description       = "HTTP from CloudFront origin-facing IPs."
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin.id
}

resource "aws_vpc_security_group_egress_rule" "origin_all_ipv4" {
  security_group_id = aws_security_group.origin.id
  description       = "All egress IPv4."
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
