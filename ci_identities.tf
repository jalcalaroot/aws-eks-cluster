# Identidades de CI para GitHub Actions via OIDC - sin ningun secreto AWS
# almacenado en GitHub. "agent" (apply, push a main) y "plan" (solo lectura,
# PRs), RBAC acotado recurso por recurso, mismo patron que
# azure-aks-cluster/ci_identities.tf y que jalcalaroot-aws-bootstrap/
# terraform/environments/dev/iam.tf.
#
# TODO antes de aplicar: el sub claim usa el sub_claim_prefix personalizado
# de esta cuenta de GitHub (formato "repo:OWNER@OWNER_ID/REPO@REPO_ID:...",
# NO el immutable subject default) - confirmado en los dos proyectos de
# referencia via `gh api repos/<owner>/<repo>/actions/oidc/customization/sub`.
# El REPO_ID de "aws-eks-cluster" no se conoce hasta crear el repo en GitHub;
# reemplazar el placeholder <REPO_ID> de abajo antes de aplicar (y verificar
# con el mismo comando `gh api`).

locals {
  github_repo_subject_prefix = "repo:jalcalaroot@22682982/aws-eks-cluster@<REPO_ID>"
}

data "aws_iam_policy_document" "ci_agent_assume_role" {
  statement {
    sid     = "HumanAssumeRole"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::740104998573:user/virtual"]
    }
  }

  statement {
    sid     = "GitHubActionsMainOnly"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_repo_subject_prefix}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "ci_agent" {
  name                 = "${var.cluster_name}-ci-agent"
  assume_role_policy   = data.aws_iam_policy_document.ci_agent_assume_role.json
  max_session_duration = 3600
  tags                 = local.tags
}

data "aws_iam_policy_document" "ci_plan_assume_role" {
  statement {
    sid     = "GitHubActionsPullRequest"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_repo_subject_prefix}:pull_request"]
    }
  }
}

resource "aws_iam_role" "ci_plan" {
  name                 = "${var.cluster_name}-ci-plan"
  assume_role_policy   = data.aws_iam_policy_document.ci_plan_assume_role.json
  max_session_duration = 3600
  tags                 = local.tags
}

# ----------------------------------------------------------------------------
# Permisos del agent - borrador razonable a partir de lo que este proyecto
# crea (EKS, Fargate, ECR, ACM, Route53, IAM para esos recursos, IRSA, y el
# backend). NO paso todavia por el ciclo de "generar con IAM Policy Autopilot
# desde el plan real + recortar a mano" que se uso para iam.tf del bootstrap
# - conviene repetir ese proceso contra el primer `terraform plan` real antes
# de confiar en esto para produccion (ver CLAUDE.md).
# ----------------------------------------------------------------------------

data "aws_iam_policy_document" "ci_agent_permissions" {
  #checkov:skip=CKV_AWS_356:Resource "*" limitado a acciones Describe/List de EKS/EC2/ECR (AWS no permite scopearlas a nivel de recurso) o a iam:PassRole acotado por condicion iam:PassedToService - ver statements individuales
  statement {
    sid = "EksClusterLifecycle"

    actions = [
      "eks:CreateCluster",
      "eks:DeleteCluster",
      "eks:DescribeCluster",
      "eks:UpdateClusterConfig",
      "eks:UpdateClusterVersion",
      "eks:TagResource",
      "eks:UntagResource",
      "eks:CreateFargateProfile",
      "eks:DeleteFargateProfile",
      "eks:DescribeFargateProfile",
      "eks:CreateAddon",
      "eks:DeleteAddon",
      "eks:DescribeAddon",
      "eks:UpdateAddon",
      "eks:CreateAccessEntry",
      "eks:DeleteAccessEntry",
      "eks:DescribeAccessEntry",
      "eks:AssociateAccessPolicy",
      "eks:DisassociateAccessPolicy",
      "eks:ListAssociatedAccessPolicies",
    ]

    resources = [
      "arn:aws:eks:us-east-1:740104998573:cluster/${var.cluster_name}",
      "arn:aws:eks:us-east-1:740104998573:fargateprofile/${var.cluster_name}/*",
      "arn:aws:eks:us-east-1:740104998573:addon/${var.cluster_name}/*/*",
    ]
  }

  statement {
    sid       = "EksReadOnly"
    actions   = ["eks:ListClusters", "eks:ListFargateProfiles", "eks:ListAddons"]
    resources = ["*"]
  }

  statement {
    sid = "IamRolesForEksLifecycle"

    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider",
    ]

    resources = [
      "arn:aws:iam::740104998573:role/${var.cluster_name}-*",
      "arn:aws:iam::740104998573:policy/${var.cluster_name}-*",
      "arn:aws:iam::740104998573:oidc-provider/*",
    ]
  }

  statement {
    sid     = "PassEksRoles"
    actions = ["iam:PassRole"]

    resources = [
      "arn:aws:iam::740104998573:role/${var.cluster_name}-*",
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["eks.amazonaws.com", "eks-fargate-pods.amazonaws.com"]
    }
  }

  statement {
    sid = "EcrLifecycle"

    actions = [
      "ecr:CreateRepository",
      "ecr:DeleteRepository",
      "ecr:DescribeRepositories",
      "ecr:PutLifecyclePolicy",
      "ecr:GetLifecyclePolicy",
      "ecr:DeleteLifecyclePolicy",
      "ecr:PutImageScanningConfiguration",
      "ecr:TagResource",
      "ecr:UntagResource",
    ]

    resources = ["arn:aws:ecr:us-east-1:740104998573:repository/${var.ecr_repository_name}"]
  }

  statement {
    sid = "AcmLifecycle"

    actions = [
      "acm:RequestCertificate",
      "acm:DeleteCertificate",
      "acm:DescribeCertificate",
      "acm:AddTagsToCertificate",
      "acm:RemoveTagsFromCertificate",
    ]

    resources = ["*"]
  }

  statement {
    sid     = "Route53CertValidation"
    actions = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]

    resources = ["arn:aws:route53:::hostedzone/${var.dns_zone_id}"]
  }

  statement {
    sid       = "Route53GetChange"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }

  statement {
    sid = "SubnetTaggingForAlbController"

    actions = ["ec2:CreateTags", "ec2:DeleteTags", "ec2:DescribeSubnets", "ec2:DescribeVpcs"]

    resources = ["*"]
  }

  # Backend remoto - state + lock file nativo de S3, scoped al key de este
  # proyecto (eks-cluster/*), mismo patron que iam.tf del bootstrap.
  statement {
    sid = "TerraformStateBackendAccess"

    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]

    resources = ["arn:aws:s3:::jalcalaroot-tfstate-740104998573/eks-cluster/*"]
  }

  statement {
    sid       = "TerraformStateBucketList"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::jalcalaroot-tfstate-740104998573"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["eks-cluster/*"]
    }
  }

  statement {
    sid       = "TerraformStateEncryption"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.us-east-1.amazonaws.com"]
    }
  }

  # --- Guardrails, mismos que iam.tf del bootstrap ---
  statement {
    sid    = "DenyPrivilegeEscalation"
    effect = "Deny"

    actions = [
      "iam:AddUserToGroup",
      "iam:AttachUserPolicy",
      "iam:CreateAccessKey",
      "iam:CreateLoginProfile",
      "iam:CreatePolicyVersion",
      "iam:CreateUser",
      "iam:PutUserPolicy",
      "iam:SetDefaultPolicyVersion",
      "iam:UpdateLoginProfile",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "DenyBillingAndOrgChanges"
    effect = "Deny"

    actions = ["account:*", "aws-portal:*", "organizations:*"]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ci_agent_permissions" {
  name   = "${var.cluster_name}-ci-agent-permissions"
  role   = aws_iam_role.ci_agent.id
  policy = data.aws_iam_policy_document.ci_agent_permissions.json
}

# ----------------------------------------------------------------------------
# Permisos del plan role - solo lectura, mismo alcance de recursos que arriba
# pero sin ninguna accion de creacion/modificacion/borrado.
# ----------------------------------------------------------------------------

data "aws_iam_policy_document" "ci_plan_permissions" {
  #checkov:skip=CKV_AWS_356:Resource "*" son Describe/List de EKS/EC2/ACM (AWS no permite scopearlos a nivel de recurso) o kms:Decrypt/GenerateDataKey acotado por condicion kms:ViaService
  statement {
    sid = "ReadOnly"

    actions = [
      "eks:DescribeCluster",
      "eks:ListClusters",
      "eks:DescribeFargateProfile",
      "eks:ListFargateProfiles",
      "eks:DescribeAddon",
      "eks:ListAddons",
      "eks:DescribeAccessEntry",
      "eks:ListAssociatedAccessPolicies",
      "ecr:DescribeRepositories",
      "ecr:GetLifecyclePolicy",
      "acm:DescribeCertificate",
      "route53:ListResourceRecordSets",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs",
      "ec2:DescribeTags",
    ]

    resources = ["*"]
  }

  statement {
    sid = "ProjectRolesReadOnly"

    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:GetOpenIDConnectProvider",
    ]

    resources = [
      "arn:aws:iam::740104998573:role/${var.cluster_name}-*",
      "arn:aws:iam::740104998573:policy/${var.cluster_name}-*",
      "arn:aws:iam::740104998573:oidc-provider/*",
    ]
  }

  statement {
    sid       = "TerraformStateRead"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::jalcalaroot-tfstate-740104998573/eks-cluster/terraform.tfstate"]
  }

  statement {
    sid       = "TerraformStateLockFile"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::jalcalaroot-tfstate-740104998573/eks-cluster/terraform.tfstate.tflock"]
  }

  statement {
    sid       = "TerraformStateBucketList"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::jalcalaroot-tfstate-740104998573"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["eks-cluster/*"]
    }
  }

  statement {
    sid       = "TerraformStateEncryption"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.us-east-1.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "ci_plan_permissions" {
  name   = "${var.cluster_name}-ci-plan-permissions"
  role   = aws_iam_role.ci_plan.id
  policy = data.aws_iam_policy_document.ci_plan_permissions.json
}
