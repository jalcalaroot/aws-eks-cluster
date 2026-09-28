# Los roles de CI (ci_agent/ci_plan) YA NO se crean aca - viven en el root
# separado ./ci (state propio, nunca se destruye junto con el cluster). Ver
# CLAUDE.md, seccion "Identidades de CI en state propio", para el porque.
# Solo se referencian por nombre para que eks.tf pueda seguir otorgandoles
# un aws_eks_access_entry (RBAC dentro del cluster, que si se destruye/
# recrea con el ciclo de vida de este root).
data "aws_iam_role" "ci_agent" {
  name = "${var.cluster_name}-ci-agent"
}

# Usado tambien en eks.tf - vivia aca antes de que este archivo tuviera los
# recursos de las identidades, se queda en el mismo lugar.
data "aws_caller_identity" "current" {}
