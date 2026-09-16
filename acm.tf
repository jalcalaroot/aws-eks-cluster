# El cert vive en ACM y el ALB Controller lo referencia DIRECTO por ARN en
# una annotation del Ingress (ver k8s/ingress.yaml) - nunca toca Kubernetes,
# ni un Secret ni un paso manual de renovacion. ACM renueva solo mientras
# exista el registro de validacion DNS en Route53.
resource "aws_acm_certificate" "this" {
  domain_name       = local.fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = var.dns_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# Registro A del FQDN final -> apunta al ALB una vez que el ALB Controller
# lo crea (alias record, sin IP fija - el ALB Controller lo actualiza el
# nombre pero no gestiona este registro; se apunta al DNS name del ALB via
# data source una vez que el Ingress ya esta aplicado, ver README paso 5).

# Segundo cert, mismo patron, para la UI de Argo CD. Comparte el MISMO ALB
# que hello-world (via group.name en los Ingress, ver k8s/) - el listener
# HTTPS soporta varios certs por SNI, uno por host, sin necesitar un
# Application Load Balancer nuevo (costo extra por hora + LCU).
resource "aws_acm_certificate" "argocd" {
  domain_name       = local.argocd_fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

resource "aws_route53_record" "argocd_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.argocd.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = var.dns_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "argocd" {
  certificate_arn         = aws_acm_certificate.argocd.arn
  validation_record_fqdns = [for r in aws_route53_record.argocd_cert_validation : r.fqdn]
}

# Las 3 apps demo de k8s-apps (podinfo/game-2048/uptime-kuma) - mismo patron
# de arriba, pero via for_each en vez de un bloque explicito por app: son 3
# certs idénticos salvo el hostname, y hello-world/argocd se dejan como
# estaban (tocarlos no aporta nada acá y son los unicos con logica propia,
# como el output separado que consume el Ingress via placeholder manual).
locals {
  demo_apps_fqdns = {
    podinfo     = local.podinfo_fqdn
    game-2048   = local.game_2048_fqdn
    uptime-kuma = local.uptime_kuma_fqdn
  }
}

resource "aws_acm_certificate" "demo_apps" {
  for_each = local.demo_apps_fqdns

  domain_name       = each.value
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

resource "aws_route53_record" "demo_apps_cert_validation" {
  for_each = {
    for pair in flatten([
      for app, cert in aws_acm_certificate.demo_apps : [
        for dvo in cert.domain_validation_options : {
          key    = app
          name   = dvo.resource_record_name
          record = dvo.resource_record_value
          type   = dvo.resource_record_type
        }
      ]
    ]) : pair.key => pair
  }

  zone_id         = var.dns_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "demo_apps" {
  for_each = aws_acm_certificate.demo_apps

  certificate_arn         = each.value.arn
  validation_record_fqdns = [aws_route53_record.demo_apps_cert_validation[each.key].fqdn]
}
