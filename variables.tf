variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "owner" {
  type    = string
  default = "johan"
}

# ============================================================================
# Red compartida (jalcalaroot-aws-bootstrap / aws-vpc) - valores copiados a
# mano, sin terraform_remote_state, mismo patron que el lado Azure.
# ============================================================================

variable "network_compute_subnet_ids" {
  description = "Subnets privadas (tier compute de aws-vpc) - donde corren los pods de Fargate. Tienen salida a internet via el NAT Gateway regional del modulo, necesaria para pull de imagenes/llamadas a la API de EKS."
  type        = list(string)
}

variable "network_public_subnet_ids" {
  description = "Subnets publicas (tier public de aws-vpc) - donde el AWS Load Balancer Controller crea el ALB internet-facing. Necesitan el tag kubernetes.io/role/elb para que el controller las descubra (ver alb_controller.tf)."
  type        = list(string)
}

variable "network_vpc_id" {
  description = "ID de la VPC compartida (vpc-jalcalaroot)"
  type        = string
}

variable "github_oidc_provider_arn" {
  description = "ARN del OIDC provider de GitHub Actions, creado una sola vez en jalcalaroot-aws-bootstrap (output github_oidc_provider_arn) - valor copiado, no remote state."
  type        = string
  default     = "arn:aws:iam::740104998573:oidc-provider/token.actions.githubusercontent.com"
}

# ============================================================================
# EKS
# ============================================================================

variable "cluster_name" {
  type    = string
  default = "eks-cluster"
}

variable "kubernetes_version" {
  description = "Version de Kubernetes. null = la version default soportada por EKS al momento del apply."
  type        = string
  default     = null
}

# ============================================================================
# ECR
# ============================================================================

variable "ecr_repository_name" {
  type    = string
  default = "hello-world"
}

# ============================================================================
# DNS + certificado
# ============================================================================

variable "dns_zone_name" {
  description = "Route53 hosted zone EXISTENTE donde se agrega el registro de este proyecto"
  type        = string
  default     = "aws.jalcalaroot.com"
}

variable "dns_zone_id" {
  description = "Zone ID de la hosted zone existente (output aws_jalcalaroot_dns_zone_id de jalcalaroot-aws-bootstrap) - valor copiado, no remote state."
  type        = string
}

variable "dns_record_name" {
  description = "Nombre del registro -> FQDN final = <dns_record_name>.<dns_zone_name>"
  type        = string
  default     = "eks"
}
