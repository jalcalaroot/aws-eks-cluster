plugin "aws" {
  enabled = true
  version = "0.35.0" # mismo valor que aws-vpc/.tflint.hcl y jalcalaroot-aws-bootstrap/terraform/.tflint.hcl - mantener en sync
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
