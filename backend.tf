# Mismo bucket S3 de tfstate que jalcalaroot-aws-bootstrap y aws-vpc, key
# distinto para no pisar esos states. Locking nativo de S3 (use_lockfile,
# TF >= 1.10) - sin DynamoDB. El bucket embebe el account ID en su nombre
# (ver el literal abajo) - Terraform no permite variables/interpolacion
# dentro de un bloque `backend`, asi que esto no se puede parametrizar
# como el resto de las referencias a este bucket en ci_identities.tf.
terraform {
  backend "s3" {
    bucket       = "jalcalaroot-tfstate-740104998573"
    key          = "eks-cluster/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
