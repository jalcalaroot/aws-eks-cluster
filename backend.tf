# Mismo bucket S3 de tfstate que jalcalaroot-aws-bootstrap y aws-vpc
# (jalcalaroot-tfstate-740104998573), key distinto para no pisar esos
# states. Locking nativo de S3 (use_lockfile, TF >= 1.10) - sin DynamoDB.
terraform {
  backend "s3" {
    bucket       = "jalcalaroot-tfstate-740104998573"
    key          = "eks-cluster/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
