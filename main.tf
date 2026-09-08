locals {
  tags = {
    Project     = "jalcalaroot"
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "terraform"
    resource    = "aws-eks-cluster"
  }

  fqdn = "${var.dns_record_name}.${var.dns_zone_name}"
}
