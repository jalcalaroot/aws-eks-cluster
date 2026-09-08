# AWS EKS Cluster

A hello-world container served over HTTPS on a custom domain, running on **Amazon Elastic Kubernetes Service (EKS)**, scheduled entirely on **AWS Fargate** — no EC2 node behind any pod — exposed via the **AWS Load Balancer Controller** with an **AWS Certificate Manager (ACM)** certificate.

## Architecture

```
                              Internet
                                 |
                    Application Load Balancer (public, managed by
                    the AWS Load Balancer Controller)
                    TLS termination (ACM cert) + HTTP -> HTTPS redirect
                                 |
                    ───── VPC-internal only below this line ─────
                                 |
                          EKS cluster (control plane, AWS-managed)
              ┌──────────────────┴──────────────────┐
       kube-system namespace              default namespace
       CoreDNS + ALB Controller           hello-world pod (nginx:alpine)
       (Fargate profile)                  (Fargate profile)
```

The Application Load Balancer is the only public entry point. Every pod in the cluster — system and workload alike — runs on Fargate: there is no EC2 node group anywhere in this project. Which pods land on Fargate is decided in Terraform, via **Fargate Profiles** that select pods by namespace (`eks.tf`), not in the pod spec itself.

This project consumes an **existing** VPC, DNS zone, and GitHub OIDC provider provisioned by a sibling bootstrap project; it does not create its own network. Design rationale and implementation notes live in [CLAUDE.md](CLAUDE.md).

## Resources deployed

| Resource | Purpose | Docs |
|---|---|---|
| EKS cluster | Managed Kubernetes control plane, `authentication_mode = API` (Access Entries, no `aws-auth` ConfigMap) | [Amazon EKS](https://aws.amazon.com/eks/) |
| Fargate profiles (`kube-system`, `default`) | Serverless compute for every pod in the cluster — CoreDNS, the ALB Controller, and the hello-world app | [Fargate Pod execution role](https://docs.aws.amazon.com/eks/latest/userguide/pod-execution-role.html) |
| AWS Load Balancer Controller (IRSA) | Public entry point; provisions and reconfigures the ALB automatically from Kubernetes `Ingress` resources | [AWS Load Balancer Controller](https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html) |
| Amazon ECR repository | Hosts the `hello-world` image | [Amazon ECR private repositories](https://docs.aws.amazon.com/AmazonECR/latest/userguide/Repositories.html) |
| ACM certificate (DNS validation) | Issued and auto-renewed by AWS, validated via a Route 53 CNAME record | [ACM DNS validation](https://docs.aws.amazon.com/acm/latest/userguide/dns-validation.html) |
| Cluster OIDC provider (IRSA) | Lets in-cluster ServiceAccounts (the ALB Controller) assume IAM roles without static credentials | [IAM roles for service accounts](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) |
| IAM roles (x2) | CI/CD identities for GitHub Actions, federated via OIDC — no stored secrets | — |
| Container Insights (CloudWatch) | EKS-specific monitoring for the cluster | — |

## Design notes

- **No EC2 node group, anywhere.** Fargate doesn't run `kube-proxy` or the VPC CNI daemonset — AWS handles pod networking directly via ENI trunking. CoreDNS runs on Fargate too, once patched post-install (see Usage) — the managed addon API doesn't expose that setting directly.
- **Fargate targeting happens in Terraform, not in the pod spec.** A Fargate Profile selects pods by namespace/labels (`eks.tf`); the pod manifests in `k8s/` have no node-targeting fields at all.
- **Two separate OIDC providers, easy to conflate.** One federates GitHub Actions into AWS for CI (`ci_identities.tf`); a completely different one federates the cluster itself for IRSA (`eks.tf`) so in-cluster ServiceAccounts can assume IAM roles. Same underlying protocol, unrelated purposes.
- **`target-type: ip` is required on the Ingress**, not optional. There's no EC2 instance behind a Fargate pod for the ALB to target the default way — it has to address the pod's IP directly.
- **Certificates never touch Kubernetes.** The ALB Controller references the ACM certificate directly by ARN via an Ingress annotation. ACM validates once (a Route 53 CNAME record) and renews automatically for as long as that record exists — no Kubernetes Secret, no manual renewal step.
- **Access Entries instead of the legacy `aws-auth` ConfigMap.** `authentication_mode = "API"` plus `aws_eks_access_entry`/`aws_eks_access_policy_association` grant cluster access declaratively in Terraform, without needing `kubectl` to bootstrap the first permissions.
- **Kubernetes manifests are plain YAML, not Terraform-managed.** Terraform's job is the infrastructure; `kubectl apply` is a separate, documented step after `terraform apply` creates the cluster.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.10
- AWS CLI, `kubectl`, and `helm`, authenticated against the target account
- [Docker](https://docs.docker.com/get-docker/)
- An existing VPC with private (compute) and public subnets
- An existing, already-delegated Route 53 hosted zone
- An existing GitHub Actions OIDC provider in the account

## Usage

1. **Download the AWS Load Balancer Controller's official IAM policy** (pinned version — not vendored in this repo, since it changes across controller releases):
   ```bash
   curl -o policies/aws-load-balancer-controller-iam-policy.json \
     https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.0/docs/install/iam_policy.json
   ```

2. **Apply the infrastructure:**
   ```bash
   terraform init
   terraform apply \
     -var "network_compute_subnet_ids=[\"subnet-...\", \"subnet-...\"]" \
     -var "network_public_subnet_ids=[\"subnet-...\", \"subnet-...\"]" \
     -var "dns_zone_id=Z..."
   ```

3. **Get cluster credentials:**
   ```bash
   aws eks update-kubeconfig --name $(terraform output -raw cluster_name)
   ```

4. **Patch CoreDNS to run on Fargate:**
   ```bash
   kubectl patch deployment coredns -n kube-system \
     -p '{"spec":{"template":{"metadata":{"annotations":{"eks.amazonaws.com/compute-type":"fargate"}}}}}'
   ```

5. **Install the AWS Load Balancer Controller via Helm**, using the IRSA role Terraform created:
   ```bash
   helm repo add eks https://aws.github.io/eks-charts
   helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
     -n kube-system \
     --set clusterName=$(terraform output -raw cluster_name) \
     --set serviceAccount.create=true \
     --set serviceAccount.name=aws-load-balancer-controller \
     --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform output -raw alb_controller_role_arn)
   ```

6. **Build and push the image:**
   ```bash
   ECR=$(terraform output -raw ecr_repository_url)
   aws ecr get-login-password | docker login --username AWS --password-stdin "${ECR%%/*}"
   docker build -t "$ECR:latest" ./docker
   docker push "$ECR:latest"
   ```

7. **Apply the manifests** (substitute the placeholders first):
   ```bash
   sed -i "s|<ECR_REPOSITORY_URL>|$ECR|" k8s/deployment.yaml
   sed -i "s|<ACM_CERTIFICATE_ARN>|$(terraform output -raw acm_certificate_arn)|" k8s/ingress.yaml
   kubectl apply -f k8s/
   ```

8. **Point the domain at the ALB** once the controller provisions it (can take a minute or two to appear):
   ```bash
   ALB_DNS=$(kubectl get ingress hello-world -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   # create a CNAME/alias record for the project's FQDN pointing at $ALB_DNS
   ```

9. Visit `https://$(terraform output -raw fqdn)`.

```bash
kubectl delete -f k8s/
helm uninstall aws-load-balancer-controller -n kube-system
terraform destroy
```

## Configuration

| Variable | Default | Notes |
|---|---|---|
| `aws_region` | `us-east-1` | |
| `owner` | `johan` | for resource tags |
| `network_compute_subnet_ids` / `network_public_subnet_ids` | — | from the network project |
| `dns_zone_id` | — | Route 53 hosted zone ID |
| `cluster_name` | `eks-cluster` | |
| `kubernetes_version` | `null` | latest EKS-supported version if unset |
| `ecr_repository_name` | `hello-world` | |
| `dns_zone_name` | `aws.jalcalaroot.com` | must already exist |
| `dns_record_name` | `eks` | final FQDN = `<dns_record_name>.<dns_zone_name>` (`eks.aws.jalcalaroot.com`) |

## Outputs

| Output | Description |
|---|---|
| `fqdn` | Public hostname |
| `cluster_name` / `cluster_endpoint` | For `aws eks update-kubeconfig` |
| `cluster_certificate_authority_data` | Sensitive |
| `cluster_oidc_provider_arn` | The cluster's own IRSA OIDC provider |
| `ecr_repository_url` | For `docker build`/`push` |
| `acm_certificate_arn` | For the Ingress annotation |
| `alb_controller_role_arn` | To annotate the ALB Controller's ServiceAccount |

## CI/CD

GitHub Actions, authenticated to AWS via OIDC — no secrets or static credentials stored in GitHub.

| Workflow | Trigger | Identity | What it does |
|---|---|---|---|
| `terraform-plan.yml` | Pull request | `eks-cluster-ci-plan` (read-only) | `fmt -check`, `validate`, tflint, Checkov (blocking, SARIF uploaded to the Security tab), `plan`, posts the plan as a PR comment |
| `terraform-apply.yml` | Push to `main` | `eks-cluster-ci-agent` (scoped to this project's resources only, plus a cluster Access Entry) | `plan` + `apply` |
| `gitleaks.yml` | PR / push to `main` | — | Secret scanning |

Both IAM roles are scoped resource-by-resource, never a blanket policy — see [CLAUDE.md](CLAUDE.md) for the full breakdown, including the note on why the CI policy is a draft that still needs verifying against a real `terraform plan` before production use.

Required GitHub repository variables (Settings → Secrets and variables → Actions → Variables): `OWNER`, `NETWORK_COMPUTE_SUBNET_IDS`, `NETWORK_PUBLIC_SUBNET_IDS` (both as a JSON array, e.g. `["subnet-a","subnet-b"]`), `DNS_ZONE_ID`.

Dependabot (`.github/dependabot.yml`) keeps Terraform providers and GitHub Actions versions current, weekly. A local `pre-commit` hook (`.pre-commit-config.yaml`) runs gitleaks + `terraform fmt` before a secret or a formatting issue ever leaves the machine.

## Cost

Main ongoing costs: the EKS control plane (~$0.10/hour, flat — unlike the pods, this runs whether or not anything is deployed), Fargate compute (billed per vCPU/memory-second while a pod runs, rounded up to the nearest supported combination), the Application Load Balancer (hourly + LCU-based), and incidental Route 53/CloudWatch usage. None of this is in the AWS Free Tier — destroy (`kubectl delete -f k8s/`, uninstall the Helm release, then `terraform destroy`) when not actively in use.

## Not covered

WAF on the ALB, fine-grained Kubernetes RBAC beyond cluster-admin, autoscaling, multi-region, network policies, private cluster endpoint.
