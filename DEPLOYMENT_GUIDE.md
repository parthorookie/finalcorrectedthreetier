# E-Commerce Platform — Complete Deployment Guide
## Event-Driven Microservices on AWS EKS (ap-south-1)

---

## REPOSITORY STRUCTURE

```
ecommerce-platform/
├── .github/workflows/
│   ├── ci.yml                    # Build → Test → SonarQube → Snyk → Trivy → ECR push
│   └── cd.yml                    # Bootstrap S3 → Terraform → ArgoCD → KEDA → Deploy
│
├── terraform/
│   ├── backend.tf                # S3 native file locking (use_lockfile=true)
│   ├── providers.tf              # AWS + Kubernetes + Helm providers
│   ├── variables.tf
│   ├── main.tf                   # Root module wiring
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── vpc/                  # VPC + subnets + NAT + route tables
│       ├── eks/                  # EKS cluster + node group + IAM roles
│       ├── aurora/               # Aurora PostgreSQL Serverless v2
│       ├── rabbitmq-ec2/         # RabbitMQ on EC2 (userdata installs Docker+RMQ)
│       ├── alb-waf/              # ALB + WAF v2 (XSS + CommonRuleSet + RateLimit)
│       ├── ecr/                  # ECR repos: backend, worker, frontend
│       └── fargate-profile/      # EKS Fargate profile for worker namespace
│
├── app/
│   ├── backend/
│   │   ├── server.js             # Express API — products + orders → RabbitMQ
│   │   ├── server.test.js        # Unit tests
│   │   ├── Dockerfile            # Multi-stage Node 18 Alpine
│   │   └── package.json
│   ├── worker/
│   │   ├── worker.js             # Consumer: exponential backoff + circuit breaker
│   │   ├── circuitBreaker.js     # CB implementation (CLOSED/OPEN/HALF_OPEN)
│   │   ├── circuitBreaker.test.js
│   │   ├── Dockerfile
│   │   └── package.json
│   └── frontend/
│       ├── index.html            # Full storefront SPA (products + cart + orders)
│       ├── nginx.conf            # Reverse proxy /api → backend
│       └── Dockerfile
│
├── helm/
│   ├── ecommerce/                # Backend + Frontend Helm chart
│   └── worker/                   # Worker Helm chart (KEDA-managed replicas)
│
├── argo/
│   ├── argocd-app-backend.yaml   # ArgoCD Application (GitOps auto-sync)
│   ├── argocd-app-worker.yaml
│   └── dlq-cronworkflow.yaml     # Argo CronWorkflow every 5min — DLQ reprocess
│
├── k8s/
│   └── keda-scaledobject.yaml    # KEDA RabbitMQ trigger (queue depth scaling)
│
├── scripts/
│   └── dlq-reprocess.sh          # Manual/Argo DLQ reprocessor with parking lot
│
├── monitoring/
│   ├── prometheus/
│   │   ├── prometheus.yml        # Scrape RabbitMQ :15692 + backend :3000
│   │   └── alerts.yml            # DLQ > 0, queue backlog, no consumers alerts
│   └── grafana/
│       ├── provisioning/         # Auto-provision datasources + dashboards
│       └── dashboards/
│           └── rabbitmq.json     # Live: queue depth, DLQ, retries, parking lot
│
├── docker/rabbitmq/
│   ├── rabbitmq.conf             # Enable prometheus plugin + load definitions
│   └── definitions.json          # Pre-create all queues/exchanges/bindings
│
├── docker-compose.yml            # Full local simulation (all 7 services)
└── sonar-project.properties
```

---

## PHASE 0 — PREREQUISITES

### Tools to install locally
```bash
# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install

# Terraform >= 1.6.0
wget https://releases.hashicorp.com/terraform/1.7.0/terraform_1.7.0_linux_amd64.zip
unzip terraform_1.7.0_linux_amd64.zip && sudo mv terraform /usr/local/bin/

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install kubectl /usr/local/bin/

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Docker + Docker Compose
sudo apt-get install -y docker.io docker-compose-plugin

# ArgoCD CLI
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install argocd /usr/local/bin/
```

### AWS IAM permissions needed
Your AWS user/role needs these policies:
- AmazonEKSFullAccess
- AmazonEC2FullAccess
- AmazonRDSFullAccess
- AmazonS3FullAccess
- AmazonECRFullAccess
- AWSWAFFullAccess
- IAMFullAccess
- ElasticLoadBalancingFullAccess
- AmazonECSFullAccess
---

## PHASE 1 — LOCAL SIMULATION WITH DOCKER COMPOSE

Run the entire stack locally before touching AWS.

### Step 1.1 — Clone and configure
```bash
git clone https://github.com/YOUR_ORG/ecommerce-platform
cd ecommerce-platform
```

### Step 1.2 — Start all services
```bash
docker compose up --build -d
```

This starts:
| Service    | URL                         | Notes                        |
|------------|-----------------------------|------------------------------|
| Frontend   | http://localhost             | Full storefront SPA          |
| Backend    | http://localhost:3000        | REST API                     |
| RabbitMQ   | http://localhost:15672       | admin / admin123             |
| Prometheus | http://localhost:9090        | Metrics scraping             |
| Grafana    | http://localhost:3001        | admin / admin                |
| Postgres   | localhost:5432               | postgres / postgres          |

### Step 1.3 — Verify services
```bash
# Backend health
curl http://localhost:3000/health

# Place a test order
curl -X POST http://localhost:3000/api/orders \
  -H "Content-Type: application/json" \
  -d '{"customer_id":"test-1","items":[{"product_id":"<id-from-products-api>","quantity":2}]}'

# List products first to get IDs
curl http://localhost:3000/api/products

# Check RabbitMQ queue depth
curl -s -u admin:admin123 http://localhost:15672/api/queues/%2F/orders \
  | python3 -m json.tool | grep '"messages"'
```

### Step 1.4 — Open Grafana Live Dashboard
1. Go to http://localhost:3001 (admin/admin)
2. The **RabbitMQ — Live Queue Dashboard** loads automatically
3. You will see LIVE:
   - 📦 Main queue depth
   - 🚨 DLQ size (red when > 0)
   - 🔁 Retry 5s / 30s queues
   - 🅿️ Parking lot count
   - 📈 Message rate (publish vs consume)
   - 👷 Active consumer count

### Step 1.5 — Test DLQ flow locally
```bash
# Simulate processing failure by stopping worker
docker compose stop worker

# Place 5 orders — they will accumulate in queue
for i in {1..5}; do
  curl -s -X POST http://localhost:3000/api/orders \
    -H "Content-Type: application/json" \
    -d "{\"customer_id\":\"test-$i\",\"items\":[{\"product_id\":\"<id>\",\"quantity\":1}]}"
done

# Watch Grafana — queue depth climbs
# Restart worker
docker compose start worker

# Run DLQ reprocessor manually
chmod +x scripts/dlq-reprocess.sh
RABBIT_HOST=localhost ./scripts/dlq-reprocess.sh --max 20
```

### Step 1.6 — Stop local stack
```bash
docker compose down -v
```

---

## PHASE 2 — AWS SETUP

### Step 2.1 — Configure AWS credentials
```bash
aws configure
# Enter: Access Key ID, Secret Access Key, Region: ap-south-1, Output: json
```

### Step 2.2 — Bootstrap Terraform S3 state bucket
```bash
BUCKET="ecommerce-terraform-state-prod"
REGION="ap-south-1"

# Create bucket WITH Object Lock enabled
aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION" \
  --object-lock-enabled-for-bucket

# Enable versioning (required for Object Lock)
aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

# Set GOVERNANCE mode — protects state from accidental deletion for 30 days
aws s3api put-object-lock-configuration \
  --bucket "$BUCKET" \
  --object-lock-configuration \
  '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"GOVERNANCE","Days":30}}}'

# Enable AES256 encryption
aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Block all public access
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "✅ State bucket ready with Object Lock (GOVERNANCE, 30 days)"
```

**Why use_lockfile=true instead of DynamoDB?**
Terraform >= 1.6.0 supports native S3 file-based locking — it writes a `.tflock` file
alongside the state. No DynamoDB table needed. Set `use_lockfile = true` in backend config.

### Step 2.3 — GitHub repository secrets
Go to: GitHub repo → Settings → Secrets and variables → Actions

Add these secrets:
```
AWS_ACCESS_KEY_ID          # Your AWS access key
AWS_SECRET_ACCESS_KEY      # Your AWS secret key
AWS_ACCOUNT_ID             # 12-digit AWS account ID
DB_PASSWORD                # Aurora master password (min 8 chars)
RABBITMQ_PASSWORD          # RabbitMQ admin password
SONAR_TOKEN                # From SonarQube → My Account → Security
SONAR_HOST_URL             # e.g. https://sonarcloud.io
SNYK_TOKEN                 # From snyk.io → Account Settings
GRAFANA_PASSWORD           # Grafana admin password for EKS
AURORA_ENDPOINT            # Filled after Terraform apply (terraform output)
RABBITMQ_IP                # Filled after Terraform apply
ALB_DNS                    # Filled after Terraform apply
```

---

## PHASE 3 — TERRAFORM INFRASTRUCTURE DEPLOYMENT

### Step 3.1 — Initialize and plan
```bash
cd terraform

# Copy example vars
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set db_password etc.

terraform init \
  -backend-config="bucket=ecommerce-terraform-state-prod" \
  -backend-config="key=prod/terraform.tfstate" \
  -backend-config="region=ap-south-1" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"

terraform validate
terraform plan -var="db_password=YOUR_PASS" -out=tfplan
```

### Step 3.2 — Apply (creates all AWS resources)
```bash
terraform apply tfplan
```

**What gets created (~15 minutes):**
| Resource                    | Details                                      |
|-----------------------------|----------------------------------------------|
| VPC                         | 10.0.0.0/16 with 2 public + 2 private subnets|
| NAT Gateway                 | In public subnet for private outbound traffic|
| EKS Cluster (1.29)          | 2 t3.medium nodes + Fargate profile for worker|
| Aurora PostgreSQL 15        | Serverless v2 (0.5–8 ACU), 2 instances       |
| RabbitMQ EC2 (t3.medium)    | Docker + RMQ 3.12 + all queues pre-created   |
| ALB                         | Internet-facing, routes /api → backend       |
| WAF v2                      | CommonRuleSet + KnownBadInputs + Rate limit  |
| ECR Repositories            | backend, worker, frontend (scan on push)     |

### Step 3.3 — Capture outputs
```bash
terraform output eks_cluster_name     # → ecommerce-eks
terraform output rabbitmq_private_ip  # → 10.0.3.x
terraform output aurora_endpoint      # → cluster.xxxxxx.ap-south-1.rds.amazonaws.com
terraform output alb_dns_name         # → ecommerce-alb-xxxx.ap-south-1.elb.amazonaws.com
```

Update GitHub secrets with these values.

### Step 3.4 — Connect kubectl to EKS
```bash
aws eks update-kubeconfig \
  --region ap-south-1 \
  --name ecommerce-eks

kubectl get nodes   # Should show 2 nodes Ready
```

---

## PHASE 4 — INSTALL CLUSTER TOOLS

### Step 4.1 — Create namespaces
```bash
kubectl create namespace argocd
kubectl create namespace worker
kubectl create namespace keda
kubectl create namespace monitoring
kubectl create namespace argo
```

### Step 4.2 — Install ArgoCD
```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version 6.7.3 \
  --wait

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo

# Port-forward ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
# → https://localhost:8080  (admin / <password above>)
```

### Step 4.3 — Install Argo Workflows
```bash
helm upgrade --install argo-workflows argo/argo-workflows \
  --namespace argo \
  --set workflow.serviceAccount.create=true \
  --wait
```

### Step 4.4 — Install KEDA
```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

helm upgrade --install keda kedacore/keda \
  --namespace keda \
  --wait

kubectl get pods -n keda   # keda-operator should be Running
```

### Step 4.5 — Install kube-prometheus-stack
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.adminPassword=admin \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --wait --timeout=600s

# Port-forward Grafana
kubectl port-forward svc/prometheus-grafana -n monitoring 3001:80
# → http://localhost:3001  (admin / admin)
```

### Step 4.6 — Create application secrets
```bash
AURORA_EP="<your-aurora-endpoint>"
DB_PASS="<your-db-password>"
RMQ_IP="<rabbitmq-ec2-private-ip>"
RMQ_PASS="<rabbitmq-password>"

kubectl create secret generic app-secrets \
  --from-literal=db-host="$AURORA_EP" \
  --from-literal=db-password="$DB_PASS" \
  --from-literal=rabbit-url="amqp://admin:${RMQ_PASS}@${RMQ_IP}:5672" \
  --namespace default

kubectl create secret generic app-secrets \
  --from-literal=db-host="$AURORA_EP" \
  --from-literal=db-password="$DB_PASS" \
  --from-literal=rabbit-url="amqp://admin:${RMQ_PASS}@${RMQ_IP}:5672" \
  --namespace worker

kubectl create secret generic rabbitmq-secret \
  --from-literal=host="$RMQ_IP" \
  --from-literal=username="admin" \
  --from-literal=password="$RMQ_PASS" \
  --from-literal=rabbit-url="amqp://admin:${RMQ_PASS}@${RMQ_IP}:5672" \
  --namespace argo
```

---

## PHASE 5 — CI/CD PIPELINE

### Step 5.1 — Push code → triggers CI
```bash
git add .
git commit -m "feat: initial platform deployment"
git push origin main
```

**CI Pipeline executes:**
```
test (unit tests + postgres + rabbitmq services)
    ↓
sonarqube (SAST static analysis)    snyk (dependency + IaC scan)
    ↓                                    ↓
              build (Docker images)
                      ↓
              trivy (container + filesystem scan → SARIF to GitHub)
                      ↓
              push-ecr (tag with git SHA + latest → ECR)
                      ↓
              commit updated helm/*/values.yaml with new image tag
```

### Step 5.2 — CD Pipeline executes automatically
```
terraform-plan
    ↓
terraform-apply (EKS + RDS + EC2 + ALB + WAF)
    ↓
install-cluster-tools (ArgoCD + Argo Workflows + KEDA + Prometheus)
    ↓
deploy-apps (ArgoCD Applications + KEDA ScaledObject + CronWorkflow)
```

### Step 5.3 — Verify deployment
```bash
# Check all pods
kubectl get pods -A

# Check backend
kubectl get deployment backend
kubectl logs deployment/backend --tail=20

# Check worker
kubectl get pods -n worker
kubectl logs -n worker deployment/worker --tail=20

# Get ALB DNS
kubectl get ingress -A
# OR: terraform output alb_dns_name
```

**Application is available at:**
```
http://<ALB_DNS_NAME>          → Frontend storefront
http://<ALB_DNS_NAME>/api/products  → Backend API
http://<ALB_DNS_NAME>/health   → Health check
```

---

## PHASE 6 — ARGOCD + GITOPS WORKFLOW

### How GitOps works in this setup:
1. Developer pushes code → CI builds + scans → pushes image to ECR
2. CI updates `helm/*/values.yaml` with new image tag + commits
3. ArgoCD detects drift → auto-syncs Helm chart to EKS
4. Zero-touch deployment — no manual `kubectl apply` needed

### Step 6.1 — Register repo in ArgoCD
```bash
argocd login localhost:8080 --username admin --password <password> --insecure

argocd repo add https://github.com/YOUR_ORG/ecommerce-platform \
  --username YOUR_GITHUB_USER \
  --password YOUR_GITHUB_PAT
```

### Step 6.2 — Apply ArgoCD applications
```bash
kubectl apply -f argo/argocd-app-backend.yaml
kubectl apply -f argo/argocd-app-worker.yaml

# Check sync status
argocd app list
argocd app get ecommerce-backend
argocd app get ecommerce-worker
```

### Step 6.3 — Force sync
```bash
argocd app sync ecommerce-backend
argocd app sync ecommerce-worker
```

---

## PHASE 7 — KEDA AUTOSCALING VERIFICATION

```bash
# Apply ScaledObject
kubectl apply -f k8s/keda-scaledobject.yaml

# Check ScaledObject
kubectl get scaledobject -n worker
kubectl describe scaledobject worker-scaler -n worker

# Watch worker replicas auto-scale as you push orders
kubectl get pods -n worker -w

# Simulate load (place 100 orders)
for i in {1..100}; do
  curl -s -X POST http://<ALB_DNS>/api/orders \
    -H "Content-Type: application/json" \
    -d '{"customer_id":"load-test","items":[{"product_id":"<id>","quantity":1}]}' &
done
wait

# Watch workers scale up (1 replica per 5 queued messages → up to 20)
kubectl get pods -n worker -w
```

---

## PHASE 8 — DLQ + ARGO CRONWORKFLOW VERIFICATION

### Step 8.1 — Apply CronWorkflow
```bash
kubectl apply -f argo/dlq-cronworkflow.yaml

# Verify
kubectl get cronworkflow -n argo
kubectl get cronworkflow dlq-reprocess -n argo -o yaml
```

### Step 8.2 — Trigger manually to test
```bash
# Install Argo CLI
curl -sLO https://github.com/argoproj/argo-workflows/releases/latest/download/argo-linux-amd64.gz
gunzip argo-linux-amd64.gz && chmod +x argo-linux-amd64
sudo mv argo-linux-amd64 /usr/local/bin/argo

argo submit --from cronwf/dlq-reprocess -n argo --watch
```

### Step 8.3 — Trigger DLQ messages manually
```bash
# Publish a message directly to DLQ (simulate failed order)
curl -s -u admin:PASSWORD \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "routing_key":"orders.dlq",
    "payload":"{\"orderId\":\"test-dlq-001\",\"items\":[]}",
    "payload_encoding":"string",
    "properties":{"headers":{"x-retry":3}}
  }' \
  http://<RMQ_IP>:15672/api/exchanges/%2F/amq.default/publish

# Watch Grafana DLQ panel — it should jump to 1
# Wait 5 minutes — Argo CronWorkflow fires and reprocesses it
```

### Step 8.4 — View workflow history
```bash
argo list -n argo
argo get @latest -n argo
argo logs @latest -n argo
```

---

## PHASE 9 — OBSERVABILITY (LIVE GRAFANA DASHBOARDS)

### What you see LIVE in Grafana:

| Panel                    | Metric                                        | Alert threshold |
|--------------------------|-----------------------------------------------|-----------------|
| 📦 Main Queue Depth      | `rabbitmq_queue_messages{queue="orders"}`     | > 100 = warning |
| 🚨 DLQ Size              | `rabbitmq_queue_messages{queue="orders.dlq"}` | > 0 = CRITICAL  |
| 🔁 Retry 5s Queue        | `rabbitmq_queue_messages{queue="orders.retry.5s"}` | > 1 = info |
| 🔁 Retry 30s Queue       | `rabbitmq_queue_messages{queue="orders.retry.30s"}` | > 1 = info|
| 🅿️ Parking Lot           | `rabbitmq_queue_messages{queue="orders.parking-lot"}` | > 0 = warn |
| 📈 Message Rate          | `rate(rabbitmq_queue_messages_published_total[1m])` | — |
| 👷 Active Consumers      | `rabbitmq_queue_consumers{queue="orders"}`    | 0 = CRITICAL    |

### Step 9.1 — Access Grafana on EKS
```bash
kubectl port-forward svc/prometheus-grafana -n monitoring 3001:80

# OR expose via LoadBalancer (for persistent access)
kubectl patch svc prometheus-grafana -n monitoring \
  -p '{"spec":{"type":"LoadBalancer"}}'
kubectl get svc prometheus-grafana -n monitoring
```

### Step 9.2 — Import dashboard manually (if not auto-loaded)
1. Open Grafana → Dashboards → Import
2. Upload `monitoring/grafana/dashboards/rabbitmq.json`
3. Select Prometheus datasource
4. Click Import

### Step 9.3 — Useful Prometheus queries
```promql
# All queue depths at once
rabbitmq_queue_messages

# Orders processed per minute
rate(rabbitmq_queue_messages_delivered_total{queue="orders"}[1m]) * 60

# DLQ alert expression
rabbitmq_queue_messages{queue="orders.dlq"} > 0

# KEDA-managed worker replicas
kube_deployment_spec_replicas{deployment="worker",namespace="worker"}

# Circuit breaker: no consumers
rabbitmq_queue_consumers{queue="orders"} == 0
```

---

## PHASE 10 — SECURITY (DevSecOps)

### SonarQube setup
1. Create account at https://sonarcloud.io (free for public repos)
2. Create project → get `SONAR_TOKEN`
3. Add token as GitHub secret `SONAR_TOKEN`
4. Add `SONAR_HOST_URL=https://sonarcloud.io` as secret
5. CI runs `sonarqube-scan-action` + quality gate check

### Snyk setup
1. Create account at https://snyk.io
2. Get API token from Account Settings
3. Add as `SNYK_TOKEN` GitHub secret
4. CI scans: npm deps (backend + worker) + Terraform IaC files

### Trivy scans (no account needed)
- Scans Docker images for CVEs (CRITICAL + HIGH)
- Scans filesystem for secrets, misconfigs
- Uploads SARIF results to GitHub Security tab
- View: GitHub repo → Security → Code scanning

### WAF rules active in production
| Rule                          | Protects Against                |
|-------------------------------|---------------------------------|
| AWSManagedRulesCommonRuleSet  | XSS, SQLi, bad inputs           |
| AWSManagedRulesKnownBadInputs | Log4j, Spring4Shell, SSRF       |
| RateLimitRule (2000/IP/5min)  | DDoS / brute-force              |

---

## PHASE 11 — TROUBLESHOOTING

### Worker not consuming messages
```bash
kubectl get pods -n worker
kubectl logs -n worker <worker-pod> --tail=50

# Check KEDA is watching
kubectl describe scaledobject worker-scaler -n worker
kubectl get hpa -n worker
```

### RabbitMQ unreachable from EKS
```bash
# Test connectivity from a debug pod
kubectl run debug --image=alpine --rm -it -- sh
apk add curl
curl -v http://<RABBITMQ_PRIVATE_IP>:15672/api/overview \
  -u admin:PASSWORD
# If timeout: check security group rules on rabbitmq-sg allows port 5672+15672 from eks-nodes-sg
```

### Aurora connection refused
```bash
# Check security group allows 5432 from EKS node SG
aws ec2 describe-security-groups --group-ids <aurora-sg-id>

# Test from EKS node
kubectl run pgtest --image=postgres:15 --rm -it -- \
  psql -h <AURORA_ENDPOINT> -U postgres -d ecommerce
```

### Terraform state lock error
```bash
# If a previous run crashed and left a .tflock file:
aws s3 rm s3://ecommerce-terraform-state-prod/prod/terraform.tfstate.tflock

# Note: With GOVERNANCE mode you may need bypass permission:
aws s3 rm s3://ecommerce-terraform-state-prod/prod/terraform.tfstate.tflock \
  --bypass-governance-retention
```

### DLQ not being reprocessed
```bash
# Check CronWorkflow
kubectl get cronworkflow -n argo
argo list -n argo

# Check rabbitmq-secret exists in argo namespace
kubectl get secret rabbitmq-secret -n argo

# Run manually
argo submit --from cronwf/dlq-reprocess -n argo --watch

# Run shell script manually
RABBIT_HOST=<RMQ_IP> RABBIT_PASS=<PASS> ./scripts/dlq-reprocess.sh --max 50
```

---

## MESSAGE FLOW DIAGRAM

```
[User Browser]
     │ POST /api/orders
     ▼
[Frontend nginx :80]
     │ proxy /api/*
     ▼
[Backend API :3000]
     │ channel.sendToQueue("orders")
     ▼
[RabbitMQ EC2]
     │
     ├─── orders (main queue, TTL DLX → orders.dlq)
     │         │
     │         ▼
     │   [Worker Pods] ←── KEDA scales 1-20 replicas based on queue depth
     │         │
     │         ├── SUCCESS → UPDATE orders SET status='confirmed' (Aurora)
     │         │
     │         └── FAILURE
     │               │
     │               ├── retry < MAX → orders.retry.5s → orders.retry.30s
     │               │               (TTL queues bounce back to orders)
     │               │
     │               └── retry >= MAX → orders.parking-lot (poison messages)
     │
     ├─── orders.dlq (dead letters from expired/nacked messages)
     │         │
     │         └── [Argo CronWorkflow every 5min]
     │               │
     │               ├── retry < MAX → re-publish to orders
     │               └── retry >= MAX → orders.parking-lot
     │
     └─── orders.parking-lot (requires manual human review)

[Prometheus :9090] ←── scrapes rabbitmq:15692 every 10s
     │
     ▼
[Grafana :3001] ←── Live dashboards, DLQ alerts
```

---

## CIRCUIT BREAKER STATE MACHINE

```
         failures < threshold            success calls
CLOSED ─────────────────────────► OPEN ◄──────────────── HALF_OPEN
  ▲                                 │    timeout expires       │
  │                                 └──────────────────────────┘
  │                                         test one call
  └──────────────────────────────────────────────────────────────
              2 consecutive successes → CLOSED
```

- **CLOSED**: Normal operation. All calls pass through.
- **OPEN**: DB is failing. Calls are rejected immediately → messages go to retry queue.
- **HALF_OPEN**: After timeout, one test call allowed. Success → CLOSED. Fail → OPEN again.

---

## COST ESTIMATE (ap-south-1 / month)

| Resource               | Type            | Estimated Cost |
|------------------------|-----------------|----------------|
| EKS Cluster            | Control plane   | ~$73/mo        |
| EC2 nodes (2x t3.med)  | Worker nodes    | ~$60/mo        |
| RabbitMQ EC2 t3.medium | On-demand       | ~$30/mo        |
| Aurora PostgreSQL       | Serverless v2   | ~$20–80/mo     |
| ALB                    | Load balancer   | ~$20/mo        |
| NAT Gateway            | Data transfer   | ~$35/mo        |
| ECR                    | Storage         | ~$5/mo         |
| **Total estimate**     |                 | **~$240–300/mo**|

💡 **Cost saving tips:**
- Use Spot instances for EKS node group (add `capacity_type = "SPOT"` in node group)
- Set KEDA `minReplicaCount: 0` to scale workers to zero when idle
- Aurora min_capacity = 0.5 ACU already ensures minimal idle cost
