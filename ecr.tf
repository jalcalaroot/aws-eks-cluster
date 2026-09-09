# El pull lo hace el Fargate pod execution role via la policy administrada
# (ver eks.tf), sin secrets ni credenciales embebidas.
resource "aws_ecr_repository" "this" {
  #checkov:skip=CKV_AWS_51:MUTABLE a proposito - se itera re-pusheando el tag "latest" mientras se prueba el hello-world
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"
  # force_delete = true: este proyecto se destruye completo despues de cada
  # sesion de prueba (patron establecido en todo el workspace). Se agrego
  # esperando que evitara "RepositoryNotEmptyException" al destruir con una
  # imagen pusheada - EN LA PRACTICA NO ALCANZO, el mismo error volvio a
  # pasar con esta flag ya puesta (posible timing: se agrego despues de
  # crear el repo, sin un apply normal de por medio antes del destroy - no
  # confirmado por que exactamente). Se termino borrando la imagen a mano
  # (`aws ecr batch-delete-image`) antes del destroy. Dejar la flag puesta
  # de todas formas (no hace daño) pero no asumir que sola alcanza.
  force_delete = true

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
