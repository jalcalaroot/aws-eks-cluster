# aws-eks-cluster

Hello-world container en EKS, corriendo 100% en Fargate (sin node pool EC2), expuesto vía AWS Load Balancer Controller con un certificado de ACM, imagen en un repo ECR dedicado, monitoreado vía Container Insights (CloudWatch).

Homólogo AWS de `azure-aks-cluster` (jalcalaroot). Construido comparando componente por componente contra ese POC — ver ahí (`CLAUDE.md`) para el lado Azure de cada decisión.

## Diferencias de diseño reales vs AKS (no solo terminología distinta)

- **Sin node pool real, punto.** AKS SIEMPRE necesita un node pool EC2/VM para CoreDNS/kube-proxy/CNI porque Virtual Nodes (ACI) no da hostNetwork. EKS Fargate no corre kube-proxy ni el VPC CNI daemonset en absoluto — el networking de cada pod lo maneja AWS directo vía ENI trunking. Resultado: este proyecto no tiene ningún recurso EC2/node pool, a diferencia de `aks.tf`'s `default_node_pool` (2 nodos obligatorios solo para hostear componentes de sistema).
- **CoreDNS sí necesita un parche manual post-apply** para correr en Fargate (`eks.amazonaws.com/compute-type: fargate`) — la EKS addon API no expone esto como `configuration_values`, así que queda como paso de README, igual que el Secret TLS manual del lado Azure.
- **El targeting a compute serverless se decide en lugares opuestos.** En Azure, un pod entra a Virtual Nodes por su propio spec (`nodeSelector` + `tolerations`) — sin eso, el scheduler lo manda al nodo real. En AWS es al revés: el Fargate Profile (definido en Terraform, por namespace/labels) decide qué pods caen en Fargate — el pod no necesita nada especial en su spec. `k8s/deployment.yaml` no tiene ningún campo equivalente a los de Azure por esto, no por descuido.
- **Sin subnet dedicada para el compute serverless.** Virtual Nodes exige un subnet delegado aparte (`snet-aks-virtual-nodes`, `/24` completo). Fargate no — usa las mismas subnets privadas que cualquier otro recurso de la VPC (`network_compute_subnet_ids`, copiadas de `aws-vpc`).
- **Pull de ECR sin secret manual.** El ACI Connector de Azure no trae credencial propia, así que Virtual Nodes necesita un `imagePullSecrets` explícito por pod. El Fargate pod execution role ya incluye permiso de pull ECR vía `AmazonEKSFargatePodExecutionRolePolicy` — funciona solo.
- **Certificado sin tocar Kubernetes.** AGIC lee el cert desde un K8s `Secret` que un humano crea a mano (`kubectl create secret tls`) y hay que recrear en cada renovación. Acá el AWS Load Balancer Controller referencia el ARN de ACM directo por annotation (`alb.ingress.kubernetes.io/certificate-arn`) — ACM renueva solo, nunca pasa por Kubernetes.
- **Dos OIDC providers distintos, fácil de confundir.** El de GitHub Actions (`var.github_oidc_provider_arn`, creado en `jalcalaroot-aws-bootstrap`, para que CI se autentique contra AWS) y el del propio cluster EKS (`aws_iam_openid_connect_provider.cluster` en `eks.tf`, para IRSA — que pods dentro del cluster asuman roles IAM). Mismo protocolo, propósitos completamente distintos. Azure no tiene este segundo mecanismo — AGIC/ACI Connector usan managed identities de Azure AD directamente, sin nada equivalente a IRSA.
- **`target-type: ip` es obligatorio en el Ingress**, no opcional — sin instancia EC2 detrás del pod, el ALB no tiene un "instance target" al que apuntar (el default del controller). Mismo tipo de gotcha silencioso que `ingressClassName` mal puesto en AGIC: si falta, el ALB Controller no crea target groups funcionales.
- **Access Entries (API) en vez de aws-auth ConfigMap.** Se usa `authentication_mode = "API"` + `aws_eks_access_entry`/`aws_eks_access_policy_association` para dar acceso al humano y al rol de CI — evita depender de `kubectl` para bootstrapear el RBAC inicial (el viejo mecanismo de ConfigMap sí lo requería). No hay equivalente a este problema en AKS porque usa Azure RBAC nativo desde el principio.

## Costo: diferencia real vs AKS

El control plane de EKS cuesta ~$0.10/hora (~$73/mes) **siempre**, tengas o no pods corriendo. AKS Free SKU (usado en `azure-aks-cluster/variables.tf`) no cobra nada por el control plane. No hay forma de evitar este costo en EKS salvo destruir el cluster cuando no se use.

## No adiviné la IAM policy del ALB Controller

`AWSLoadBalancerControllerIAMPolicy` es grande (~20 statements) y cambia entre releases del controller — escribirla de memoria tenía riesgo real de quedar incompleta o desactualizada. En vez de eso, `alb_controller.tf` la carga vía `file()` desde `policies/aws-load-balancer-controller-iam-policy.json`, que el README instruye a descargar del repo oficial (`kubernetes-sigs/aws-load-balancer-controller`, versión pineada) antes del primer apply. Ese archivo no está en el repo — es un prerrequisito documentado, no un artefacto versionado (podría quedar desactualizado silenciosamente si se versiona).

## CI IAM policy — borrador, no verificado contra un apply real

A diferencia de `jalcalaroot-aws-bootstrap/terraform/environments/dev/iam.tf` (cuya policy se generó con IAM Policy Autopilot a partir de un `terraform show -json` real y se recortó a mano), la policy de `ci_identities.tf` en este proyecto es un borrador razonado a partir de qué recursos crea el código — **no pasó por ese mismo proceso de verificación empírica todavía**. Antes de confiar en esto para un pipeline de CI real: correr `terraform plan` con credenciales amplias, generar el borrador de policy desde ese plan, y recortar a mano como se hizo en el bootstrap.

## OIDC subject claim — placeholder sin resolver

`ci_identities.tf` tiene un placeholder literal `<REPO_ID>` en el sub claim (formato `repo:jalcalaroot@22682982/aws-eks-cluster@<REPO_ID>:...`) — confirmado como el formato correcto (sub_claim_prefix personalizado, no el immutable subject default) contra los dos precedentes reales de esta cuenta (`azure-aks-cluster` y `jalcalaroot-aws-bootstrap`), pero el ID numérico del repo no existe hasta crear `aws-eks-cluster` en GitHub. Reemplazar y verificar con `gh api repos/jalcalaroot/aws-eks-cluster/actions/oidc/customization/sub` antes de aplicar — no asumir.

## Backend

Mismo bucket S3 de tfstate que `jalcalaroot-aws-bootstrap` y `aws-vpc` (`jalcalaroot-tfstate-740104998573`), key `eks-cluster/terraform.tfstate`, locking nativo S3 (`use_lockfile`, sin DynamoDB).

## Relación con el proyecto de red

Lee (valores copiados, sin `terraform_remote_state`): `network_compute_subnet_ids`, `network_public_subnet_ids`, `network_vpc_id` de `aws-vpc`; `github_oidc_provider_arn`, `dns_zone_id` de `jalcalaroot-aws-bootstrap`. Mismo patrón que el lado Azure — copiar valores, no acoplar states.

## Consumidores

Ninguno — proyecto hoja, nada más lee sus outputs.

## Pendiente antes de un apply real

1. Descargar `policies/aws-load-balancer-controller-iam-policy.json` (ver README)
2. Crear el repo `aws-eks-cluster` en GitHub, resolver `<REPO_ID>` en `ci_identities.tf`
3. Completar `network_compute_subnet_ids`/`network_public_subnet_ids`/`network_vpc_id`/`dns_zone_id` con los valores reales de `aws-vpc`/`jalcalaroot-aws-bootstrap` (no tienen default a propósito, mismo patrón que `subscription_id` del lado Azure — obliga a pasarlos explícitamente, sin un default que invite a aplicar sobre la red equivocada)
4. Revisar el borrador de IAM policy de CI contra un plan real (ver arriba)
