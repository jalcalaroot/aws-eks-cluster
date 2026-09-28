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

variable "cluster_name" {
  description = "Debe coincidir con el cluster_name del root principal - los nombres/ARNs de los roles y el scope de sus policies se derivan de este valor."
  type        = string
  default     = "eks-cluster"
}

variable "ecr_repository_name" {
  type    = string
  default = "hello-world"
}

variable "dns_zone_id" {
  description = "Zone ID de la hosted zone existente (output aws_jalcalaroot_dns_zone_id de jalcalaroot-aws-bootstrap) - valor copiado, no remote state."
  type        = string
}

variable "github_repo_subject_prefix" {
  description = "OIDC subject prefix para este repo, formato 'repo:<org>@<org-id>/<repo>@<repo-id>' -- ver `gh api repos/<org>/<repo>/actions/oidc/customization/sub`."
  type        = string
}

variable "github_oidc_provider_arn" {
  description = "ARN del OIDC provider de GitHub Actions, creado una sola vez en jalcalaroot-aws-bootstrap (output github_oidc_provider_arn) - valor copiado, no remote state."
  type        = string
}
