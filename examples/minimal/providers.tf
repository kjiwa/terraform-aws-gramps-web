provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "gramps-web"
      ManagedBy = "terraform"
    }
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "gramps-web"
      ManagedBy = "terraform"
    }
  }
}
