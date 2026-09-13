# CloudWatch Container Insights en un cluster 100% Fargate no puede usar el
# addon estandar (amazon-cloudwatch-observability) - ese depende de un
# DaemonSet + acceso directo al kubelet/cAdvisor del nodo, y Fargate no
# expone ninguna de las dos cosas (no hay nodo real detras del pod). La via
# soportada por AWS para Fargate es un ADOT Collector (AWS Distro for
# OpenTelemetry) que llama a la API del cluster para que esta le haga de
# proxy hacia el endpoint /metrics/cadvisor de cada nodo Fargate - ver
# k8s/container-insights.yaml y CLAUDE.md para el detalle verificado contra
# la doc oficial (https://aws-otel.github.io/docs/getting-started/container-insights/eks-fargate).
#
# Mismo motivo que argocd/keda: namespace nuevo = Fargate Profile nuevo.
resource "aws_eks_fargate_profile" "container_insights" {
  cluster_name           = aws_eks_cluster.this.name
  fargate_profile_name   = "container-insights"
  pod_execution_role_arn = aws_iam_role.fargate_pod_execution.arn
  subnet_ids             = var.network_compute_subnet_ids

  selector {
    namespace = "fargate-container-insights"
  }

  tags = local.tags
}

# IRSA para el ADOT Collector - misma mecanica que alb_controller.tf (rol
# federado via el OIDC provider del cluster, sin credenciales estaticas).
# La policy es la managed policy oficial de AWS para este caso
# (CloudWatchAgentServerPolicy), no una custom - es lo que documenta AWS
# para este setup especifico, sin necesidad de acotarla mas.
resource "aws_iam_role" "adot_collector" {
  name = "${var.cluster_name}-adot-collector"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.cluster.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:sub" = "system:serviceaccount:fargate-container-insights:adot-collector"
          "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "adot_collector" {
  role       = aws_iam_role.adot_collector.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}
