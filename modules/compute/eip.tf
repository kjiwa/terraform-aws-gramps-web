resource "aws_eip" "origin" {
  domain = "vpc"

  tags = {
    Name = "gramps-web-origin"
  }
}
