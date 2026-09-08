# IRSA para el AWS Load Balancer Controller - le da permiso al controller
# para gestionar el load balancer sin credenciales estaticas, asumiendo un
# rol IAM federado via el OIDC provider del propio cluster.
#
# La policy IAM oficial (AWSLoadBalancerControllerIAMPolicy) es grande y
# cambia entre versiones del controller - en vez de escribirla a mano desde
# memoria (riesgo real de quedar desactualizada/incorrecta), se descarga del
# repo oficial antes del primer apply:
#
#   curl -o policies/aws-load-balancer-controller-iam-policy.json \
#     https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
#
# Ver README para el paso completo, incluida la version pineada recomendada.

resource "aws_iam_role" "alb_controller" {
  name = "${var.cluster_name}-alb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.cluster.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_policy" "alb_controller" {
  name   = "${var.cluster_name}-alb-controller"
  policy = file("${path.module}/policies/aws-load-balancer-controller-iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# El ALB Controller descubre subnets por tag, no por config explicita en el
# Helm chart. Subnets publicas -> internet-facing ALB; subnets privadas
# (compute) -> quedarian tageadas para internal-elb si algun dia se agrega
# un Ingress interno, no se usa en este proyecto.
resource "aws_ec2_tag" "public_subnet_elb" {
  for_each = toset(var.network_public_subnet_ids)

  resource_id = each.value
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

resource "aws_ec2_tag" "compute_subnet_cluster" {
  for_each = toset(var.network_compute_subnet_ids)

  resource_id = each.value
  key         = "kubernetes.io/cluster/${var.cluster_name}"
  value       = "shared"
}

resource "aws_ec2_tag" "public_subnet_cluster" {
  for_each = toset(var.network_public_subnet_ids)

  resource_id = each.value
  key         = "kubernetes.io/cluster/${var.cluster_name}"
  value       = "shared"
}
