# Photo Gallery — Diagram Specifications

Four diagrams. Each lists: actors/nodes (grouped by cluster, with the AWS
service each one represents), then every edge as an ordered step with its
label. Solid arrows = primary/synchronous flow. Dashed arrows = async,
one-time, or an alternate/reference path. Where a real AWS icon should be
used, the service name is exact; anything not an AWS service (GitHub,
Developer/User, generic labels) should use a generic icon instead.

---

## 1. Architecture (steady state)

**Title:** Photo Gallery — AWS Architecture
**Layout intent:** Left column = external actors (User, CloudFront, S3,
KMS, CloudWatch). Top band = GitHub + CI/CD. Center = VPC with nested
subnet clusters. Flows generally left-to-right / top-to-bottom.

### Nodes / clusters

- **End users (browser)** — generic person/actor icon
- **GitHub** (cluster, generic, not AWS)
  - **photo-uploader-app** — Django, Dockerfile, taskdef/appspec (generic repo icon)
  - **photo-uploader-infra** — CloudFormation (generic repo icon)
- **GitHub OIDC role** — AWS IAM (Identity and Access Management) — label: "no long-lived keys"
- **CloudFront** — AWS CloudFront — label: "Price Class 200"
- **VPC (Multi-AZ)** (cluster)
  - **Internet Gateway** — AWS Internet Gateway (VPC)
  - **Public subnets (AZ-a / AZ-b)** (cluster)
    - **Application Load Balancer** — AWS Application Load Balancer (ALB)
  - **VPC Endpoints (no NAT)** (cluster)
    - **Endpoint: ECR / S3 / Logs / Secrets Manager / SSM** — AWS VPC Endpoint (generic/interface endpoint icon)
  - **Private subnets (AZ-a / AZ-b)** (cluster)
    - **ECS Fargate service (1-4 tasks)** (cluster)
      - **Blue task set** — AWS ECS (Elastic Container Service) task/container
      - **Green task set** — AWS ECS task/container
    - **RDS PostgreSQL** — AWS RDS — label: "db.t3, Multi-AZ standby replica"
- **S3: images** — AWS S3 — label: "private, KMS"
- **KMS CMK** — AWS KMS (Key Management Service)
- **CloudWatch Logs** — AWS CloudWatch — label: "/ecs/photo-gallery"
- **CI/CD** (cluster)
  - **ECR: app image** — AWS ECR (Elastic Container Registry)
  - **EventBridge rule** — AWS EventBridge — label: "ECR push"
  - **CodePipeline** — AWS CodePipeline
  - **CodeDeploy** — AWS CodeDeploy — label: "blue/green"

### Flow — end user viewing the gallery

1. End users →(HTTPS)→ CloudFront
2. CloudFront →(OAC)→ S3: images
3. End users →(HTTP)→ Application Load Balancer
4. Application Load Balancer →(:8000)→ Blue task set
5. Internet Gateway → Application Load Balancer

### Flow — app data path

6. Blue task set →(R/W)→ RDS PostgreSQL
7. Blue task set →(upload)→ S3: images
8. Blue task set → CloudWatch Logs
9. RDS PostgreSQL ⇢(encrypted with, dashed)⇢ KMS CMK
10. S3: images ⇢(encrypted with, dashed)⇢ KMS CMK

### Flow — app code CI/CD (triggered by app repo pushes)

11. photo-uploader-app →(OIDC assume-role)→ GitHub OIDC role
12. GitHub OIDC role →(docker push)→ ECR: app image
13. ECR: app image →(ECR Image Action)→ EventBridge rule
14. EventBridge rule →(start execution)→ CodePipeline
15. photo-uploader-app ⇢(dashed: source — taskdef.json / appspec.yaml)⇢ CodePipeline
16. CodePipeline → CodeDeploy
17. CodeDeploy →(shift traffic)→ Green task set (blue/green cutover)

### Flow — infra CI/CD (triggered by infra repo pushes)

18. photo-uploader-infra →(solid, green: "ongoing — GitHub Actions OIDC → cfn deploy root.yaml")→ VPC Endpoints (representing: this is what deploys/updates the whole VPC + everything inside it)
19. photo-uploader-infra ⇢(dashed, green: "one-time — Git sync")⇢ ECR: app image (representing: this is the separate, rare path that deploys `bootstrap.yaml` and the persistent `ecr.yaml` stack — shown landing near ECR because `ecr.yaml` owns that repository; it is NOT the same pipeline as flow 18)

---

## 2. CI/CD push flow — application code

**Title:** Photo Gallery — Developer Push to Deploy (Application)
**Layout intent:** Strict left-to-right pipeline, one clear step at a time.

### Nodes / clusters

- **Developer** — generic actor icon
- **GitHub: photo-uploader-app** (cluster)
  - **main branch** — generic repo icon
  - **GitHub Actions** — generic CI icon — label: "test, build, docker push"
- **GitHub OIDC role** — AWS IAM — label: "github-actions-ecr-push, no long-lived keys"
- **ECR: app image** — AWS ECR
- **AWS: CI/CD pipeline** (cluster)
  - **EventBridge rule** — AWS EventBridge — label: "image push, tag=latest"
  - **CodePipeline** — AWS CodePipeline
  - **CodeDeploy** — AWS CodeDeploy — label: "ECS blue/green"
- **ECS Fargate service** (cluster)
  - **Blue task set** — AWS ECS — label: "current prod"
  - **Green task set** — AWS ECS — label: "new revision"
- **CloudWatch alarms** — AWS CloudWatch — label: "target group health"

### Flow (numbered, strictly sequential unless noted parallel)

1. Developer →(git push)→ main branch
2. main branch →(triggers on push)→ GitHub Actions
3. GitHub Actions →(assume role, OIDC)→ GitHub OIDC role
4. GitHub OIDC role →(docker push :latest, :sha)→ ECR: app image
5. ECR: app image →(ECR Image Action — PUSH, SUCCESS)→ EventBridge rule
6. EventBridge rule →(start execution)→ CodePipeline
   - **parallel, dashed:** main branch ⇢(source: ecs/taskdef.json + ecs/appspec.yaml)⇢ CodePipeline
7. CodePipeline →(create deployment)→ CodeDeploy
8. CodeDeploy →(install new task definition)→ Green task set
9. CodeDeploy →(bold: shift prod traffic to green, then terminate blue)→ Green task set
   - Green task set ⇢(dotted)⇢ CloudWatch alarms
   - Blue task set ⇢(dotted)⇢ CloudWatch alarms
10. CloudWatch alarms ⇢(dashed, red/warning: auto-rollback on alarm)⇢ CodeDeploy

---

## 3. Infra push flow — infrastructure code

**Title:** Photo Gallery — Developer Push to Deploy (Infrastructure)
**Layout intent:** Left-to-right main pipeline (steps 1–6); a visually
separate, smaller side-cluster below/beside it for the rare Git-sync path,
NOT chained inline with the main pipeline (it's an independent trigger).

### Nodes / clusters

- **Developer** — generic actor icon
- **GitHub: photo-uploader-infra** (cluster)
  - **main branch** — generic repo icon
  - **GitHub Actions** — generic CI icon — label: "deploy-root-stack.yml — triggers on root.yaml / stacks/** / deployments/root.yaml"
- **InfraDeployRole** — AWS IAM — label: "dual-trust: GitHub OIDC + cloudformation.amazonaws.com, no long-lived keys"
- **TemplatesBucket** — AWS S3 — label: "packaged nested-stack templates, never committed"
- **CloudFormation deploy** — AWS CloudFormation — label: "aws cloudformation deploy root.yaml"
- **"9 nested stacks, updated in one pass"** (cluster, target of step 6 — draw as 4 representative sub-icons)
  - Network / Security / VPC Endpoints — AWS VPC (generic)
  - ECS + ALB (blue/green) — AWS ECS + AWS ALB
  - RDS PostgreSQL — AWS RDS
  - CodePipeline / CodeDeploy / EventBridge — AWS CodePipeline (representative)
- **"One-time / rare — Git sync, no GitHub Actions run at all"** (cluster, visually separate/off to the side)
  - **bootstrap.yaml + ecr.yaml** — AWS CloudFormation (generic stack icon)

### Flow — ongoing, every push touching root.yaml/stacks/deployments

1. Developer →(git push)→ main branch
2. main branch →(triggers on push)→ GitHub Actions (deploy-root-stack.yml)
3. GitHub Actions →(assume role, OIDC)→ InfraDeployRole
4. InfraDeployRole →(aws cloudformation package)→ TemplatesBucket
5. TemplatesBucket →(--template-file, packaged)→ CloudFormation deploy
   - **parallel, dashed:** InfraDeployRole ⇢(aws cloudformation deploy --role-arn — also the CFN execution role)⇢ CloudFormation deploy
6. CloudFormation deploy →(create/update)→ each of the 4 items inside "9 nested stacks, updated in one pass"

### Flow — one-time / rare, independent of the above

- main branch ⇢(dashed, green: "Git sync — only when those two flat templates change")⇢ bootstrap.yaml + ecr.yaml
  (No GitHub Actions run at all for this path — CloudFormation Git sync
  handles it directly, since these are flat, non-nested templates.)

---

## 4. User upload flow — visitor views & uploads a photo

**Title:** Photo Gallery — Visitor Views & Uploads a Photo
**Layout intent:** Visitor on the left. Two interleaved flows sharing the
same actor and ALB/Django node: a numbered "view" flow (1,3,5,6,7,8) and a
lettered "upload" flow (A,C,D,F). Keep the two flows visually distinguishable
(e.g. different arrow colors) since they share endpoints but are separate
requests.

### Nodes / clusters

- **Visitor (browser)** — generic actor icon
- **CloudFront** — AWS CloudFront — label: "image delivery, OAC"
- **Application Load Balancer** — AWS ALB
- **ECS Fargate task (private subnet)** (cluster)
  - **Django app** — AWS ECS — label: "Gunicorn, :8000"
- **Private subnet** (cluster, separate from the ECS one, placed near it)
  - **RDS PostgreSQL** — AWS RDS — label: "Photo: image key, description"
- **S3: images** — AWS S3 — label: "private, KMS, read only via CloudFront"
- **KMS CMK** — AWS KMS

### Flow — numbered: viewing the gallery

1. Visitor →(GET /)→ Application Load Balancer → Django app
3. Django app →(SELECT photos)→ RDS PostgreSQL
5. Django app →(HTML response)→ (via ALB) → Visitor
6. Visitor →(GET each image — HTTPS, direct)→ CloudFront
7. CloudFront →(cache miss → fetch via OAC)→ S3: images
8. CloudFront →(image bytes)→ Visitor

### Flow — lettered: uploading a photo

A. Visitor →(POST /upload — multipart: image + description)→ Application Load Balancer → Django app
C. Django app →(validate: size ≤ 8MB, Pillow check; then put_object — task role, SSE-KMS)→ S3: images
D. Django app →(INSERT Photo — image key, description)→ RDS PostgreSQL
F. Django app →(302 + success)→ (via ALB) → Visitor

### Encryption reference (dashed, no directional meaning beyond "encrypted with")

- S3: images ⇢⇢ KMS CMK
