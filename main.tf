locals {
  tags = {
    Project     = "jalcalaroot"
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "terraform"
    resource    = "aws-eks-cluster"
  }

  fqdn        = "${var.dns_record_name}.${var.dns_zone_name}"
  argocd_fqdn = "${var.dns_record_name_argocd}.${var.dns_zone_name}"

  podinfo_fqdn     = "${var.dns_record_name_podinfo}.${var.dns_zone_name}"
  game_2048_fqdn   = "${var.dns_record_name_game_2048}.${var.dns_zone_name}"
  uptime_kuma_fqdn = "${var.dns_record_name_uptime_kuma}.${var.dns_zone_name}"
}
