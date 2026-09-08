# Cluster 100% Fargate: a diferencia de AKS (que SIEMPRE necesita un node
# pool real para CoreDNS/kube-proxy/CNI, porque Virtual Nodes/ACI no da
# hostNetwork), EKS Fargate no corre kube-proxy ni el daemonset del VPC CNI
# en absoluto - AWS maneja el networking de cada pod directo via ENI
# trunking. CoreDNS SI puede correr en Fargate una vez parcheado (ver
# README). Resultado: no hace falta ningun EC2/node pool real en este
# proyecto - simplificacion real vs el companion "system" node pool que
# aks.tf necesita.
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids = var.network_compute_subnet_ids
  }

  # Access Entries (API) en vez del aws-auth ConfigMap legacy - evita
  # depender de kubectl para el bootstrap inicial de permisos RBAC.
  access_config {
    authentication_mode = "API"
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]

  tags = local.tags
}

# El usuario humano (mismo principal que en jalcalaroot-aws-bootstrap) y el
# rol de CI "agent" necesitan un Access Entry propio + la policy de admin
# de cluster para poder correr kubectl/Helm (instalar el ALB controller,
# aplicar los manifests de k8s/).
resource "aws_eks_access_entry" "human" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = "arn:aws:iam::740104998573:user/virtual"
}

resource "aws_eks_access_policy_association" "human_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.human.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

resource "aws_eks_access_entry" "ci_agent" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.ci_agent.arn
}

resource "aws_eks_access_policy_association" "ci_agent_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.ci_agent.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# ------------------------------------------------------------------------
# Fargate: pod execution role + profiles.
# ------------------------------------------------------------------------

resource "aws_iam_role" "fargate_pod_execution" {
  name = "${var.cluster_name}-fargate-pod-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks-fargate-pods.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        ArnLike = {
          "aws:SourceArn" = "arn:aws:eks:${var.aws_region}:740104998573:fargateprofile/${var.cluster_name}/*"
        }
      }
    }]
  })
}

# AmazonEKSFargatePodExecutionRolePolicy ya incluye
# ecr:GetAuthorizationToken/BatchGetImage/GetDownloadUrlForLayer - a
# diferencia del ACI Connector en Azure (que NO trae identidad propia y
# obliga a un imagePullSecret manual por pod), aca el pull de ECR funciona
# sin ningun secret adicional.
resource "aws_iam_role_policy_attachment" "fargate_pod_execution_policy" {
  role       = aws_iam_role.fargate_pod_execution.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
}

# Namespace kube-system: CoreDNS (una vez parcheado, ver README) y el ALB
# Controller.
resource "aws_eks_fargate_profile" "kube_system" {
  cluster_name           = aws_eks_cluster.this.name
  fargate_profile_name   = "kube-system"
  pod_execution_role_arn = aws_iam_role.fargate_pod_execution.arn
  subnet_ids             = var.network_compute_subnet_ids

  selector {
    namespace = "kube-system"
  }

  tags = local.tags
}

# Namespace default: el hello-world. En Azure, que un pod caiga en Virtual
# Nodes se decide DENTRO del pod (nodeSelector + tolerations). En Fargate
# es al reves: el targeting se decide ACA, a nivel de Fargate Profile
# (namespace/labels) - el pod no necesita nada especial en su spec.
resource "aws_eks_fargate_profile" "default" {
  cluster_name           = aws_eks_cluster.this.name
  fargate_profile_name   = "default"
  pod_execution_role_arn = aws_iam_role.fargate_pod_execution.arn
  subnet_ids             = var.network_compute_subnet_ids

  selector {
    namespace = "default"
  }

  tags = local.tags
}

# ------------------------------------------------------------------------
# OIDC provider del CLUSTER, para IRSA (IAM Roles for Service Accounts) -
# distinto del OIDC provider de GitHub Actions (ese es para que CI se
# autentique contra AWS; este es para que pods DENTRO del cluster asuman
# roles IAM, ej. el ALB controller en alb_controller.tf). Facil confundir
# los dos, son mecanismos separados con el mismo protocolo por debajo.
# ------------------------------------------------------------------------

data "tls_certificate" "cluster_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster_oidc.certificates[0].sha1_fingerprint]

  tags = local.tags
}

# EKS managed addon de CoreDNS - igual necesita el patch manual post-apply
# para que corra en Fargate (ver README), la addon API no expone
# compute-type como configuration_values.
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_fargate_profile.kube_system]

  tags = local.tags
}
