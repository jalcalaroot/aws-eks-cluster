# Homologo de acr.tf. Sin admin user (no existe ese concepto en ECR) - el
# pull lo hace el Fargate pod execution role via la policy administrada
# (ver eks.tf), sin secrets ni credenciales embebidas.
resource "aws_ecr_repository" "this" {
  #checkov:skip=CKV_AWS_51:MUTABLE a proposito - se itera re-pusheando el tag "latest" mientras se prueba el hello-world, igual que el flujo documentado para ACR (sin retention policy de Premium ahi tampoco)
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Mantener solo las ultimas 5 imagenes - una sola app hello-world en este proyecto"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}
