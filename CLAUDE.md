# aws-eks-cluster

Hello-world container en EKS, corriendo 100% en Fargate (sin node pool EC2), expuesto vía AWS Load Balancer Controller con un certificado de ACM, imagen en un repo ECR dedicado, monitoreado vía Container Insights (CloudWatch). También aloja **Argo CD** (Helm, namespace `argocd`) — el controller GitOps que sincroniza [`aws-eks-apps`](https://github.com/jalcalaroot/aws-eks-apps) contra este cluster; ver README para el install completo.

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
- **El ALB Controller necesita `vpcId`/`region` explícitos en el Helm install.** Por defecto intenta auto-descubrir el VPC vía metadata de instancia EC2 (IMDS) - que no existe en Fargate (no hay instancia EC2 detrás del pod). Sin esto, crash-loops al arrancar con `failed to get VPC ID: ... ec2imds: GetMetadata, request canceled`. Encontrado en el primer deploy real (ver "Deploy real" abajo).
- **Todo namespace nuevo necesita su propio Fargate Profile, sin excepciones.** `argocd` no es distinto de `default` en esto - se agregó `aws_eks_fargate_profile.argocd` en `eks.tf` antes de instalar Argo, o los pods se hubieran quedado `Pending` para siempre. Documentado también del lado de `aws-eks-apps/CLAUDE.md` para cualquier app nueva que necesite namespace propio.
- **Argo CD corre con `server.insecure: true`.** El ALB ya termina TLS con el cert de ACM - si el backend de Argo también sirve HTTPS (su default), queda un mismatch/redirect loop. `insecure` hace que el pod sirva HTTP plano puertas adentro, mismo patrón que cualquier otra app detrás de este ALB.
- **Un ALB compartido entre apps, via `alb.ingress.kubernetes.io/group.name`.** `hello-world` y Argo CD comparten el mismo Application Load Balancer (grupo `eks-demo-apps`) en vez de uno cada uno - el listener HTTPS soporta varios certs por SNI, uno por host. Requiere que CADA Ingress del grupo tenga `spec.rules[].host` explícito - sin eso, una regla sin host matchea cualquier hostname que llegue, tapando las reglas de las otras apps del grupo (le pasó a `hello-world`: su Ingress original no tenía `host`, funcionaba bien solo, y hubiera roto el ruteo de Argo si no se corregía al agregarlo al grupo).
- **Agregar `group.name` a un Ingress existente cambia la identidad del ALB.** El ALB de grupo es un recurso distinto al ALB standalone que tenía `hello-world` antes - al aplicar el cambio, el ALB viejo se borra y aparece uno nuevo con DNS name distinto. **El registro Route 53 que apuntaba al ALB viejo queda huérfano/roto** hasta que se actualiza a mano al nuevo DNS name - pasó en la práctica, `eks.aws.jalcalaroot.com` dejó de resolver hasta corregir el CNAME.

## Gotcha externo: el VPC Endpoint de S3 puede romper el pull de imágenes (no es bug de este repo)

Si la VPC de red (`aws-vpc`) tiene el S3 Gateway Endpoint con una policy restrictiva tipo "same account only", **todo pull de imagen de cualquier pod en Fargate/ECS falla con 403** - los registros de contenedores (ECR, pero también Quay.io y probablemente otros) guardan las capas en buckets S3 propios, accedidos vía URL pre-firmada que no lleva el `aws:PrincipalAccount` del llamador de la forma que ese guardrail espera. Pasó dos veces en la práctica: primero con el pull de CoreDNS (bucket de ECR), después con el pull de Argo CD (`quay.io/argoproj/argocd`, un bucket de Quay.io completamente distinto) - confirmando que no es un problema de un registro puntual, sino del guardrail mismo siendo incompatible con correr workloads de contenedores en general.

**Fix real, en `aws-vpc` (`endpoints.tf`, `v0.6.3`)**: se sacó la policy restrictiva del S3 Gateway Endpoint por completo (whitelisting bucket por bucket no escala - ver `aws-vpc/CLAUDE.md` para el detalle, incluidos dos intentos previos que no alcanzaron: v0.6.1 solo cubría el bucket de ECR, y v0.6.2 pensó que remover el argumento `policy` alcanzaba pero no - `policy` es Optional+Computed, omitirlo no revierte nada ya aplicado). Si algún día se apunta este proyecto a una VPC con una versión de `aws-vpc` anterior a v0.6.3, va a fallar de la misma forma - no hay nada que hacer del lado de `aws-eks-cluster`, es responsabilidad de la versión del módulo de red.

## Costo

El control plane de EKS cuesta ~$0.10/hora (~$73/mes) **siempre**, tengas o no pods corriendo — no hay forma de evitarlo salvo destruir el cluster cuando no se use.

## No adiviné la IAM policy del ALB Controller

`AWSLoadBalancerControllerIAMPolicy` es grande (~20 statements) y cambia entre releases del controller — escribirla de memoria tenía riesgo real de quedar incompleta o desactualizada. En vez de eso, `alb_controller.tf` la carga vía `file()` desde `policies/aws-load-balancer-controller-iam-policy.json`, que el README instruye a descargar del repo oficial (`kubernetes-sigs/aws-load-balancer-controller`, versión pineada) antes de cada `init`/`plan`/`apply`. Ese archivo está gitignored — es un prerrequisito descargado en cada corrida (incluido en CI, ver más abajo), no un artefacto versionado que podría quedar desactualizado silenciosamente.

## CI IAM policy — verificada contra un apply real (2026-09-08)

Se verificó corriendo el pipeline de CI de verdad (push a `main` tras agregar Argo CD) en vez de solo razonar qué necesitaba - y encontró gaps reales que el borrador original no tenía:
- `eks:DescribeAccessEntry` estaba en `actions` pero el `resources` de `EksClusterLifecycle` no incluía ARNs de tipo `access-entry` - denegado por resource mismatch, no por accion faltante (gotcha sutil: tener la accion listada no alcanza si el resource scope no la cubre).
- Faltaban `acm:ListTagsForCertificate`, `ecr:ListTagsForResource`, `ec2:DescribeTags` (este último faltaba solo en `ci_agent`, `ci_plan` ya lo tenía) - los tres son llamadas que Terraform hace en el `refresh` de cada `plan`/`apply` para leer tags existentes, no algo que uno anticiparía leyendo solo qué recursos se crean.

Los gaps se corrigieron en `ci_identities.tf` a partir de los errores reales de cada run fallido (`gh run view --log`), uno por uno - mismo método que `iam.tf` del bootstrap (generar/ajustar contra el error real), aunque sin pasar por IAM Policy Autopilot. Costó 3 rondas: los primeros 4 gaps (arriba) en una, un quinto (`route53:GetHostedZone`, necesario para refrescar `aws_route53_record` ademas de `ListResourceRecordSets`) recién apareció una vez resueltos esos. Confirmar contra un futuro cambio grande de recursos (ej. otro namespace/Fargate Profile) que no aparezcan gaps nuevos del mismo tipo.

**Gotcha de bootstrap circular, no obvio**: el fix de una IAM policy que el propio `ci_agent` usa **no se puede aplicar corriendo el pipeline de CI otra vez** - el `terraform plan` de esa misma corrida necesita los permisos NUEVOS para poder hacer `refresh` de los recursos existentes, pero esos permisos nuevos recién existirían DESPUÉS de un `apply` exitoso que el pipeline nunca llega a correr. Cada uno de los 3 fixes de arriba se aplicó primero con `terraform apply -target=aws_iam_role_policy.ci_agent_permissions -target=aws_iam_role_policy.ci_plan_permissions` usando credenciales propias (`arn:aws:iam::<account-id>:user/virtual`, con permiso amplio), y recién ahí se reintentó el pipeline. Sin este paso manual, el pipeline queda atascado reintentando el mismo error para siempre por más commits que se le agreguen al policy document.

## OIDC subject claim — resuelto

Repo creado el 2026-09-08 (`jalcalaroot/aws-eks-cluster`, id numérico propio, público). El sub claim en `ci_identities.tf` usa `repo:<org>@<org-id>/<repo>@<repo-id>:...` — confirmado ese mismo día vía `gh api repos/jalcalaroot/aws-eks-cluster/actions/oidc/customization/sub` (sub_claim_prefix personalizado de esta cuenta, no el immutable subject default). Si el repo se renombra en el futuro, este ID sigue siendo válido (es estable, la parte de texto no) pero **hay que volver a correr ese mismo `gh api` para confirmarlo** — no asumir que el ID no cambió solo porque el nombre visible cambió.

## Seguridad y CI

- **Pre-commit** (`.pre-commit-config.yaml`): gitleaks + `terraform_fmt` en cada commit local, antes de que un secreto llegue a salir de la máquina.
- **`gitleaks.yml`**: mismo scanning en CI (PR + push a `main`), por si alguien no tiene el hook instalado localmente.
- **`terraform-plan.yml`** (PR): `fmt -check`, `validate`, tflint (`tflint-ruleset-aws`), Checkov (bloqueante, `soft_fail: false`, sube SARIF a la pestaña Security del repo), `plan` comentado en el PR con warning si destruye/reemplaza recursos.
- **`terraform-apply.yml`** (push a `main`): `plan` + `apply` directo, sin schedule periódico — a diferencia de un certificado que necesita renovación manual, el cert de ACM (`acm.tf`) renueva solo mientras exista el registro de validación en Route 53.
- **Dependabot** (`.github/dependabot.yml`): actualiza versiones de providers Terraform y de las GitHub Actions usadas en los workflows, semanal.
- **`SECURITY.md`**: reporte privado de vulnerabilidades vía GitHub private vulnerability reporting, no issues públicos.

Ambos roles de CI (`ci_agent`/`ci_plan`) requieren estas GitHub Actions repository **variables** (no secrets, no son sensibles): `OWNER`, `NETWORK_COMPUTE_SUBNET_IDS` y `NETWORK_PUBLIC_SUBNET_IDS` (como JSON, ej. `["subnet-a","subnet-b"]`), `DNS_ZONE_ID`.

## Backend

Mismo bucket S3 de tfstate que `jalcalaroot-aws-bootstrap` y `aws-vpc` (`jalcalaroot-tfstate-<account-id>`), key `eks-cluster/terraform.tfstate`, locking nativo S3 (`use_lockfile`, sin DynamoDB).

## Relación con el proyecto de red

Lee (valores copiados, sin `terraform_remote_state`): `network_compute_subnet_ids`, `network_public_subnet_ids` de `aws-vpc`; `github_oidc_provider_arn`, `dns_zone_id` de `jalcalaroot-aws-bootstrap`.

## Variable eliminada: `network_vpc_id`

Estaba declarada en `variables.tf` pero ningún recurso la usaba — tflint (`terraform_unused_declarations`) lo marcó al correr el linter localmente antes del primer commit de CI. Se eliminó en vez de dejarla como dead code (junto con sus referencias en los workflows y el README). Distinto del output `vpc_id` agregado después (ver abajo) — ese sí hace falta, para el Helm install del ALB Controller.

## Deploy real verificado (2026-09-08)

`terraform apply` completo (34 recursos) + Helm install del ALB Controller + build/push de la imagen + `kubectl apply` de los manifests, contra una VPC real (`jalcalaroot-dev`, redesplegada para esta prueba). Confirmado end-to-end: `https://eks.aws.jalcalaroot.com` responde `200`, contenido correcto, certificado ACM válido (`CN=eks.aws.jalcalaroot.com`, sin `-k`/skip-verify).

Dos problemas reales encontrados y corregidos en el camino (ninguno de los dos era un bug obvio antes de intentarlo):
1. El gotcha del S3 Gateway Endpoint (ver sección arriba) - tardó ~20 min en manifestarse porque `terraform apply` esperó ese tiempo a que el addon de CoreDNS sanara solo, sin lograrlo.
2. El gotcha de `vpcId`/`region` del ALB Controller en Fargate (ver Decisiones de diseño).

Ninguno de los dos estaba documentado de antemano en este repo - ambos son el tipo de cosa que solo aparece con un deploy real, no con `terraform plan`.

Nota aparte: aplicar el fix del S3 endpoint en la VPC real requirió `-target` en el `terraform apply` de `jalcalaroot-aws-bootstrap` - un `apply` sin `-target` ahí habría revertido los tags `kubernetes.io/cluster/*`/`kubernetes.io/role/elb` que este proyecto agrega a las subnets compartidas vía `aws_ec2_tag` (recurso de un state distinto al del módulo de VPC, por lo que el módulo los ve como drift y los "corrige" borrándolos). Si se vuelve a tocar `aws-vpc` en el futuro con este proyecto ya desplegado, hay que repetir ese cuidado o agregar `lifecycle.ignore_changes` sobre tags sensibles a extensión externa en el módulo mismo.

## Argo CD instalado (2026-09-08) - Fargate Profile + cert + ALB compartido

Segunda ronda de deploy real, agregando Argo CD sobre el cluster ya funcionando. Cambios en Terraform: `aws_eks_fargate_profile.argocd` (namespace nuevo, mismo patrón que `default`/`kube-system`), segundo cert ACM + validación DNS para `argocd.aws.jalcalaroot.com` (`acm.tf`, mismo patrón que el FQDN principal, resources separados no un `for_each` para no arriesgar el cert ya en uso). Instalado via Helm (`argo/argo-cd`, chart 10.8.2), no Terraform - mismo criterio que el ALB Controller.

Encontrado en el camino (además del gotcha de S3 de arriba, que se manifestó de nuevo acá con un bucket distinto):
- `hello-world`'s Ingress original no tenía `host:` - al meterlo en el mismo Ingress Group que Argo, hubo que agregárselo (ver Decisiones de diseño) para que no tape la regla de Argo.
- Agregar `group.name` a un Ingress ya desplegado **reemplaza el ALB** (identidad de recurso distinta) - el registro Route 53 de `hello-world` quedó apuntando al ALB viejo (ya borrado) hasta corregirlo a mano. Si se agrega una app más al grupo en el futuro, el ALB ya existe y no debería volver a pasar - pero vale la pena confirmar el DNS name del Ingress después de cualquier cambio de `group.name`, no asumir que sigue igual.

Verificado end-to-end: `https://argocd.aws.jalcalaroot.com` responde 200 (7 pods de Argo `1/1 Running`), `https://eks.aws.jalcalaroot.com` sigue funcionando en el mismo ALB compartido tras el fix del DNS.

## Consumidores

Ninguno — proyecto hoja, nada más lee sus outputs.

## Estado del pipeline de CI (2026-09-08)

Todo lo que sigue ya se hizo, dejado como registro de qué costó llegar a un pipeline que corre de verdad (no son pasos pendientes):

1. `policies/aws-load-balancer-controller-iam-policy.json` se descarga en cada corrida de CI (`mkdir -p policies` primero - el directorio no existe en un checkout limpio, gotcha real que rompió **todas** las corridas de CI desde que existe este repo hasta que se encontró, ver commit "Fix CI: mkdir policies/...").
2. Las GitHub Actions repository variables (`OWNER`, `NETWORK_COMPUTE_SUBNET_IDS`, `NETWORK_PUBLIC_SUBNET_IDS`, `DNS_ZONE_ID`) estaban documentadas como necesarias pero nunca se habían seteado - CI fallaba con variables Terraform vacías hasta que se corrigió (`gh variable set ...`).
3. La IAM policy de CI, verificada contra un apply real - ver sección arriba.

Contraejemplo útil para la próxima vez: **`terraform plan`/`apply` local con credenciales amplias nunca iba a encontrar ninguno de estos 3 problemas** - los tres solo existen en el entorno de CI (checkout limpio, variables de repo, rol de IAM acotado). "Funciona en mi máquina" no prueba que el pipeline funcione.

## PLAN (no implementado, decidido 2026-09-08) — cert wildcard + External DNS

Motivación: cada subdominio nuevo (`eks.*`, `argocd.*`) hoy necesita un `aws_acm_certificate` + validación DNS dedicados en este repo - no escala si `aws-eks-apps` va a seguir agregando apps con Ingress propio (ver su README, sección "Roadmap"). Decidido con el usuario: pasar a un cert wildcard + External DNS antes de construir esas apps nuevas.

**Cambios pendientes en este repo cuando se retome:**

1. **`acm.tf`**: reemplazar `aws_acm_certificate.this` + `aws_acm_certificate.argocd` (2 certs, 2 sets de validación) por UN solo `aws_acm_certificate` con `domain_name = "*.aws.jalcalaroot.com"` y `subject_alternative_names = ["aws.jalcalaroot.com"]` (el apex no queda cubierto por el wildcard solo, se agrega como SAN aparte - gratis, ACM no cobra por SAN adicional). Puede generar 1 o 2 registros de validación DNS segun como los procese ACM - el `for_each` sobre `domain_validation_options` ya existente lo maneja sin cambios.
2. **`k8s/ingress.yaml`** (hello-world) y el `helm install` de Argo CD (README, paso 8): apuntar `certificate-arn` al ARN del cert wildcard nuevo, no a los 2 viejos.
3. **Instalar External DNS** via Helm en `kube-system` (mismo namespace/Fargate Profile que el ALB Controller, sin necesitar uno nuevo) - IRSA propio (mismo patron que `alb_controller.tf`), permisos minimos documentados por AWS: `route53:ChangeResourceRecordSets`, `route53:ListResourceRecordSets`, `route53:ListHostedZones`, acotados a la hosted zone de este proyecto (`domainFilters` en los values del chart, no a nivel IAM - `ListHostedZones` no es scopeable a una zone especifica).
4. **Borrar a mano** los 2 registros Route53 CNAME creados manualmente esta sesión (`eks.aws.jalcalaroot.com`, `argocd.aws.jalcalaroot.com`, via `aws route53 change-resource-record-sets`, nunca gestionados por Terraform) - dejar que External DNS los cree y sea dueño desde cero (su TXT registry no adopta registros pre-existentes que no creó él mismo; si no se borran, External DNS los ignora en silencio y esos dos quedan fuera del sistema nuevo aunque las apps futuras sí entren).
5. Decidir política de External DNS: `upsert-only` (default, no borra registros al borrar el Ingress - mas seguro) vs `sync` (limpieza automática al borrar una app - mejor higiene pero mas sorpresivo). No decidido todavía.
6. Documentar todo esto en el README (reemplaza el paso 8/9 actual de instalación de Argo + el registro DNS manual).

**Por qué no se hizo ya**: se decidió el approach pero se priorizó dar de baja el cluster/VPC al final de la sesión (ver más abajo) antes de implementar - para no dejar la cuenta con infra corriendo de un cambio a medio terminar.
