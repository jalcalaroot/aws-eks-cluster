locals {
  tags = {
    Project     = "jalcalaroot"
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "terraform"
    resource    = "aws-eks-cluster-ci"
  }
}
