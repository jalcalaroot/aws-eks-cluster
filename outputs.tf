output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  value     = aws_eks_cluster.this.certificate_authority[0].data
  sensitive = true
}

output "cluster_oidc_provider_arn" {
  description = "ARN del OIDC provider del cluster (IRSA) - distinto del OIDC provider de GitHub Actions"
  value       = aws_iam_openid_connect_provider.cluster.arn
}

output "ecr_repository_url" {
  value = aws_ecr_repository.this.repository_url
}

output "acm_certificate_arn" {
  value = aws_acm_certificate_validation.this.certificate_arn
}

output "fqdn" {
  description = "Dominio publico final - el registro A hacia el ALB se crea manualmente despues del kubectl apply (ver README)"
  value       = local.fqdn
}

output "alb_controller_role_arn" {
  description = "ARN a anotar en el ServiceAccount del ALB Controller (eks.amazonaws.com/role-arn) al instalarlo via Helm"
  value       = aws_iam_role.alb_controller.arn
}

output "argocd_fqdn" {
  description = "Dominio publico de la UI de Argo CD"
  value       = local.argocd_fqdn
}

output "argocd_acm_certificate_arn" {
  value = aws_acm_certificate_validation.argocd.certificate_arn
}

output "vpc_id" {
  description = "Necesario para --set vpcId= al instalar el ALB Controller via Helm - sin esto intenta auto-descubrir el VPC via IMDS, que no existe en Fargate (ver CLAUDE.md)"
  value       = aws_eks_cluster.this.vpc_config[0].vpc_id
}
