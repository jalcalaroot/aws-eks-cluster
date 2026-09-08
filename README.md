# aws-eks-cluster

Hello-world container en EKS, corriendo 100% en Fargate (sin node pool EC2), expuesto vía AWS Load Balancer Controller con un certificado de ACM, imagen en un repo ECR dedicado, monitoreado vía Container Insights (CloudWatch).

Homólogo AWS del POC `azure-aks-cluster` (AKS + Virtual Nodes + AGIC + ACR + Let's Encrypt). Ver `CLAUDE.md` para el detalle de las diferencias de diseño.

## Prerrequisitos

- Terraform >= 1.10
- `kubectl`, `helm`, `aws` CLI configurados
- Antes de crear el repo en GitHub y aplicar: reemplazar el placeholder `<REPO_ID>` en `ci_identities.tf` (ver el TODO en ese archivo)

## Pasos de deploy

1. **Descargar la IAM policy oficial del ALB Controller** (versión pineada, no se hardcodea en este repo porque cambia entre releases):

   ```bash
   curl -o policies/aws-load-balancer-controller-iam-policy.json \
     https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.0/docs/install/iam_policy.json
   ```

2. **`terraform init && terraform apply`** — crea el cluster EKS, los Fargate profiles, ECR, el cert de ACM (validado vía Route53), el rol IRSA del ALB Controller, y las identidades de CI.

3. **Parchear CoreDNS para que corra en Fargate** (la EKS addon API no expone esto como config, hay que hacerlo a mano — igual que en Azure el Secret TLS es un paso manual):

   ```bash
   kubectl patch deployment coredns -n kube-system \
     --type json \
     -p '[{"op": "remove", "path": "/spec/template/metadata/annotations/eks.amazonaws.com~1compute-type"}]' 2>/dev/null || true
   kubectl patch deployment coredns -n kube-system \
     -p '{"spec":{"template":{"metadata":{"annotations":{"eks.amazonaws.com/compute-type":"fargate"}}}}}'
   ```

4. **Instalar el AWS Load Balancer Controller vía Helm**, con el ServiceAccount anotado con el rol IRSA (`terraform output -raw alb_controller_role_arn`):

   ```bash
   helm repo add eks https://aws.github.io/eks-charts
   helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
     -n kube-system \
     --set clusterName=$(terraform output -raw cluster_name) \
     --set serviceAccount.create=true \
     --set serviceAccount.name=aws-load-balancer-controller \
     --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform output -raw alb_controller_role_arn)
   ```

5. **Build + push de la imagen a ECR**:

   ```bash
   aws ecr get-login-password | docker login --username AWS --password-stdin $(terraform output -raw ecr_repository_url | cut -d/ -f1)
   docker build -t $(terraform output -raw ecr_repository_url):latest docker/
   docker push $(terraform output -raw ecr_repository_url):latest
   ```

6. **Sustituir placeholders y aplicar los manifests**:

   ```bash
   sed -i "s|<ECR_REPOSITORY_URL>|$(terraform output -raw ecr_repository_url)|" k8s/deployment.yaml
   sed -i "s|<ACM_CERTIFICATE_ARN>|$(terraform output -raw acm_certificate_arn)|" k8s/ingress.yaml
   kubectl apply -f k8s/
   ```

7. **Crear el registro A del FQDN** una vez que el ALB Controller aprovisiona el ALB (puede tardar 1-2 min en aparecer):

   ```bash
   ALB_DNS=$(kubectl get ingress hello-world -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   # Crear un registro CNAME/alias en la zona aws.jalcalaroot.com apuntando a $ALB_DNS
   ```

## Costo

El control plane de EKS cuesta ~$0.10/hora (~$73/mes) sin importar si hay pods corriendo — a diferencia de AKS (Free tier, $0). Cada pod en Fargate se cobra por vCPU/memoria solicitada mientras corre, redondeado a la combinación soportada más cercana. El ALB también tiene costo por hora + por LCU. Nada de esto está en el free tier — destruir (`terraform destroy`, en orden inverso: primero `kubectl delete -f k8s/` y desinstalar el Helm release, después el `terraform destroy`) cuando no se esté usando activamente.
