# aws-eks-cluster

Hello-world container en EKS, corriendo 100% en Fargate (sin node pool EC2), expuesto vía AWS Load Balancer Controller con un certificado de ACM, imagen en un repo ECR dedicado, monitoreado vía Container Insights (CloudWatch).

## Decisiones de diseño

- **Sin node pool real, punto.** Fargate no corre `kube-proxy` ni el daemonset del VPC CNI — el networking de cada pod lo maneja AWS directo vía ENI trunking, así que no hace falta ningún nodo EC2 solo para hostear componentes de sistema. Este proyecto no tiene ningún recurso EC2/node pool.
- **CoreDNS necesita un parche manual post-apply** para correr en Fargate (`eks.amazonaws.com/compute-type: fargate`) — la EKS addon API no expone esto como `configuration_values`, así que queda documentado como paso de README.
- **El targeting a Fargate se decide en Terraform, no en el pod spec.** Un Fargate Profile (`eks.tf`) selecciona pods por namespace/labels — `k8s/deployment.yaml` no tiene ningún campo de node-targeting, a propósito.
- **Sin subnet dedicada para Fargate.** Usa las mismas subnets privadas que cualquier otro recurso de la VPC (`network_compute_subnet_ids`, copiadas de `aws-vpc`).
- **Pull de ECR sin secret manual.** El Fargate pod execution role ya incluye permiso de pull ECR vía `AmazonEKSFargatePodExecutionRolePolicy` — funciona solo, sin `imagePullSecrets`.
- **Certificado sin tocar Kubernetes.** El AWS Load Balancer Controller referencia el ARN de ACM directo por annotation (`alb.ingress.kubernetes.io/certificate-arn`) — ACM renueva solo mientras exista el registro de validación en Route 53, nunca pasa por un Kubernetes Secret.
- **Dos OIDC providers distintos, fácil de confundir.** El de GitHub Actions (`var.github_oidc_provider_arn`, creado en `jalcalaroot-aws-bootstrap`, para que CI se autentique contra AWS) y el del propio cluster EKS (`aws_iam_openid_connect_provider.cluster` en `eks.tf`, para IRSA — que pods dentro del cluster asuman roles IAM). Mismo protocolo, propósitos completamente distintos.
- **`target-type: ip` es obligatorio en el Ingress**, no opcional — sin instancia EC2 detrás del pod, el ALB no tiene un "instance target" al que apuntar (el default del controller). Si falta, el ALB Controller no crea target groups funcionales, sin error visible.
- **Access Entries (API) en vez de aws-auth ConfigMap.** `authentication_mode = "API"` + `aws_eks_access_entry`/`aws_eks_access_policy_association` dan acceso al humano y al rol de CI declarativamente en Terraform, sin depender de `kubectl` para bootstrapear el RBAC inicial.

## Costo

El control plane de EKS cuesta ~$0.10/hora (~$73/mes) **siempre**, tengas o no pods corriendo — no hay forma de evitarlo salvo destruir el cluster cuando no se use.

## No adiviné la IAM policy del ALB Controller

`AWSLoadBalancerControllerIAMPolicy` es grande (~20 statements) y cambia entre releases del controller — escribirla de memoria tenía riesgo real de quedar incompleta o desactualizada. En vez de eso, `alb_controller.tf` la carga vía `file()` desde `policies/aws-load-balancer-controller-iam-policy.json`, que el README instruye a descargar del repo oficial (`kubernetes-sigs/aws-load-balancer-controller`, versión pineada) antes de cada `init`/`plan`/`apply`. Ese archivo está gitignored — es un prerrequisito descargado en cada corrida (incluido en CI, ver más abajo), no un artefacto versionado que podría quedar desactualizado silenciosamente.

## CI IAM policy — borrador, no verificado contra un apply real

A diferencia de `jalcalaroot-aws-bootstrap/terraform/environments/dev/iam.tf` (cuya policy se generó con IAM Policy Autopilot a partir de un `terraform show -json` real y se recortó a mano), la policy de `ci_identities.tf` en este proyecto es un borrador razonado a partir de qué recursos crea el código — **no pasó por ese mismo proceso de verificación empírica todavía**. Antes de confiar en esto para un pipeline de CI real: correr `terraform plan` con credenciales amplias, generar el borrador de policy desde ese plan, y recortar a mano con el mismo método.

## OIDC subject claim — resuelto

Repo creado el 2026-09-08 (`jalcalaroot/aws-eks-cluster`, id `1361551904`, público). El sub claim en `ci_identities.tf` usa `repo:jalcalaroot@22682982/aws-eks-cluster@1361551904:...` — confirmado ese mismo día vía `gh api repos/jalcalaroot/aws-eks-cluster/actions/oidc/customization/sub` (sub_claim_prefix personalizado de esta cuenta, no el immutable subject default). Si el repo se renombra en el futuro, este ID sigue siendo válido (es estable, la parte de texto no) pero **hay que volver a correr ese mismo `gh api` para confirmarlo** — no asumir que el ID no cambió solo porque el nombre visible cambió.

## Seguridad y CI

- **Pre-commit** (`.pre-commit-config.yaml`): gitleaks + `terraform_fmt` en cada commit local, antes de que un secreto llegue a salir de la máquina.
- **`gitleaks.yml`**: mismo scanning en CI (PR + push a `main`), por si alguien no tiene el hook instalado localmente.
- **`terraform-plan.yml`** (PR): `fmt -check`, `validate`, tflint (`tflint-ruleset-aws`), Checkov (bloqueante, `soft_fail: false`, sube SARIF a la pestaña Security del repo), `plan` comentado en el PR con warning si destruye/reemplaza recursos.
- **`terraform-apply.yml`** (push a `main`): `plan` + `apply` directo, sin schedule periódico — a diferencia de un certificado que necesita renovación manual, el cert de ACM (`acm.tf`) renueva solo mientras exista el registro de validación en Route 53.
- **Dependabot** (`.github/dependabot.yml`): actualiza versiones de providers Terraform y de las GitHub Actions usadas en los workflows, semanal.
- **`SECURITY.md`**: reporte privado de vulnerabilidades vía GitHub private vulnerability reporting, no issues públicos.

Ambos roles de CI (`ci_agent`/`ci_plan`) requieren estas GitHub Actions repository **variables** (no secrets, no son sensibles): `OWNER`, `NETWORK_COMPUTE_SUBNET_IDS` y `NETWORK_PUBLIC_SUBNET_IDS` (como JSON, ej. `["subnet-a","subnet-b"]`), `DNS_ZONE_ID`.

## Backend

Mismo bucket S3 de tfstate que `jalcalaroot-aws-bootstrap` y `aws-vpc` (`jalcalaroot-tfstate-740104998573`), key `eks-cluster/terraform.tfstate`, locking nativo S3 (`use_lockfile`, sin DynamoDB).

## Relación con el proyecto de red

Lee (valores copiados, sin `terraform_remote_state`): `network_compute_subnet_ids`, `network_public_subnet_ids` de `aws-vpc`; `github_oidc_provider_arn`, `dns_zone_id` de `jalcalaroot-aws-bootstrap`.

## Variable eliminada: `network_vpc_id`

Estaba declarada en `variables.tf` pero ningún recurso la usaba — tflint (`terraform_unused_declarations`) lo marcó al correr el linter localmente antes del primer commit de CI. Se eliminó en vez de dejarla como dead code (junto con sus referencias en los workflows y el README).

## Consumidores

Ninguno — proyecto hoja, nada más lee sus outputs.

## Pendiente antes de un apply real

1. Descargar `policies/aws-load-balancer-controller-iam-policy.json` localmente (ver README) — en CI se descarga solo, en cada corrida
2. Completar `network_compute_subnet_ids`/`network_public_subnet_ids`/`dns_zone_id` con los valores reales de `aws-vpc`/`jalcalaroot-aws-bootstrap` (no tienen default a propósito — obliga a pasarlos explícitamente, sin invitar a aplicar sobre la red equivocada)
3. Setear las GitHub Actions repository variables listadas arriba, para que `terraform-plan.yml`/`terraform-apply.yml` funcionen
4. Revisar el borrador de IAM policy de CI contra un plan real (ver arriba)
