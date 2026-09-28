# Mismo bucket S3 de tfstate que el resto de la cuenta, key propio para no
# pisar el state principal de este repo (eks-cluster/terraform.tfstate).
# Root deliberadamente separado - ver CLAUDE.md, seccion "Identidades de CI
# en state propio".
terraform {
  backend "s3" {
    bucket       = "jalcalaroot-tfstate-<AWS_ACCOUNT_ID>"
    key          = "eks-cluster-ci/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
