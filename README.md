# Photo Gallery — Infrastructure (CloudFormation + Git Sync)

Infrastructure-as-code for a highly available, containerized photo gallery on
ECS Fargate. This repo is deployed via **AWS CloudFormation Git sync** — no
`aws cloudformation deploy` from a laptop, no Terraform, no CDK. Every stack
here is wired to watch this repo's `main` branch; pushing a change to a
template or its deployment file re-deploys that stack automatically (via a
pull request CloudFormation opens on this repo).

Application code lives in a separate repo: **photo-uploader-app**.

## Architecture

```
Internet ──HTTPS──▶ CloudFront (Price Class 200) ──OAC──▶ S3 (private, KMS)
Internet ──HTTP───▶ ALB (public subnets, 2 AZ)
                       │
                       ▼
              ECS Fargate service (private subnets, 2 AZ)
              ├─ Blue target group  (prod listener :80)
              └─ Green target group (test listener :8080)
                       │
                       ▼
              RDS PostgreSQL (private subnets, db.t3)

No NAT Gateway by default — ECS tasks reach ECR, S3, CloudWatch Logs and
Secrets Manager entirely through VPC interface/gateway endpoints.

ECR push ──▶ EventBridge rule ──▶ CodePipeline ──▶ CodeDeploy (blue/green) ──▶ ECS
```

See [`diagrams/architecture_diagram.py`](diagrams/architecture_diagram.py) for
the full diagram-as-code source (`diagrams` / mingrammer). Render it with:

```bash
pip install diagrams
# install the Graphviz `dot` binary for your OS (brew/apt/choco install graphviz)
cd diagrams && python architecture_diagram.py   # -> architecture.png
```

## Stack layout

Each file under `templates/` is deployed as its **own independent stack**
(CloudFormation Git sync stacks are not nested). Stacks share state via
`Export`/`Fn::ImportValue`, so they must be created **in this order**:

| # | Template | Creates | Depends on |
|---|----------|---------|------------|
| 00 | `00-network.yaml` | VPC, public/private subnets (2 AZ), routing, S3 gateway endpoint | — |
| 01 | `01-security.yaml` | Security groups, shared KMS CMK | 00 |
| 02 | `02-vpc-endpoints.yaml` | Interface endpoints: ECR api/dkr, CloudWatch Logs, Secrets Manager | 00, 01 |
| 03 | `03-storage-cdn.yaml` | S3 image bucket, CloudFront + OAC, access-logs bucket | 01 |
| 04 | `04-database.yaml` | RDS PostgreSQL, Secrets Manager credentials | 00, 01 |
| 05 | `05-ecr.yaml` | ECR repository for the app image | 01 |
| 06 | `06-github-oidc.yaml` | GitHub OIDC provider + role for CI | — |
| 07 | `07-ecs-alb.yaml` | ALB (2 target groups, 2 listeners), ECS cluster/service/task def | 00, 01, 03, 04, 05 |
| 08 | `08-autoscaling.yaml` | Application Auto Scaling (1–4 tasks, CPU target tracking) | 07 |
| 09 | `09-cicd-pipeline.yaml` | CodeStar connection, CodePipeline, CodeDeploy blue/green, EventBridge trigger | 05, 07 |

## One-time prerequisites (console, unavoidable manual steps)

CloudFormation Git sync and CodePipeline's GitHub source both rely on **AWS
CodeConnections**, which requires a one-time interactive OAuth handshake —
this cannot be scripted or done via CloudFormation itself.

1. **Link this repo for Git sync**: CloudFormation console → *Stacks* →
   *Create stack* → *With new resources* → *Sync from Git* → *Link a Git
   repository* → GitHub → authorize AWS's GitHub App for this repo.
2. Repeat step 1's authorization for the **application** repo when you reach
   stack `09` (CodePipeline needs its own `AWS::CodeStarConnections::Connection`
   pointed at `photo-uploader-app` — the template creates the connection
   resource, but you must open **Developer Tools → Connections** in the
   console once after stack `09` is created and click **Update pending
   connection** to complete the handshake).

## Deploying, in order

For each stack (00 → 09), in the CloudFormation console:

1. *Create stack* → *With new resources* → *Prerequisite: Choose an existing
   template* → *Specify template: Sync from Git*.
2. Stack name: e.g. `photo-gallery-dev-network` (matches the template).
3. Stack deployment file: **I am providing my own file in my repository** →
   deployment file path: `deployments/00-network.yaml` (matches the number).
4. Template definition repository: the linked `photo-uploader-infra` repo,
   branch `main`.
5. Template file path: `templates/00-network.yaml`.
6. IAM role: let CloudFormation generate a new one (least privilege for that
   stack's resource types).
7. Submit → CloudFormation opens a PR on this repo → merge it → the stack is
   created. Future pushes to templates/deployment files on `main`
   auto-update the stack.

Before creating stack `05` (`ecr`), edit `deployments/06-github-oidc.yaml`
and set `GitHubOrg` to your real GitHub org/username. After stack `06` is
created, copy its `GitHubActionsRoleArn` output into
`deployments/05-ecr.yaml`'s `GitHubActionsRoleArn` parameter and push — Git
sync will update the ECR repository policy to allow that role to push.

Before creating stack `09`, edit its deployment file with your real
`GitHubOrg` / `GitHubAppRepo`.

## Bootstrapping the first deploy

`07-ecs-alb.yaml` starts the ECS service on a placeholder image
(`public.ecr.aws/docker/library/httpd:2.4`) so the service has something
valid to run before your app image exists. Once:

1. The application repo's GitHub Actions workflow has pushed at least one
   image tagged `latest` to ECR, and
2. Stack `09` (the pipeline) exists,

the EventBridge rule fires automatically and CodeDeploy performs the first
real blue/green deployment, replacing the placeholder with your Django app.

## Getting the ALB endpoint

```bash
aws cloudformation list-exports \
  --query "Exports[?Name=='photo-gallery-dev-AlbDnsName'].Value" --output text
```

## Cost / security choices worth knowing about

- **No NAT Gateway by default** (`EnableNatGateway: "false"`). ECS tasks
  never need general internet egress — ECR, S3, CloudWatch Logs and Secrets
  Manager are all reached via VPC endpoints. Saves ~$32/mo per AZ plus data
  processing charges. Flip to `"true"` in `deployments/00-network.yaml` if
  the app ever needs outbound internet access.
- **RDS Multi-AZ is off by default** (`DBMultiAZ: "false"`) — the VPC itself
  is Multi-AZ (subnets in 2 AZs) per the requirement, but a standby RDS
  replica roughly doubles DB cost. Flip on for a real production posture.
- **S3 bucket is fully private**; CloudFront reads it only via Origin Access
  Control scoped to this exact distribution ARN (`AWS:SourceArn` condition).
- **All data at rest is KMS-encrypted** with a single rotated CMK (S3, RDS,
  Secrets Manager, ECR, CloudWatch Logs).
- **CI/CD uses OIDC** (`06-github-oidc.yaml`) — the GitHub Actions role has
  no long-lived AWS credentials and is scoped to one repo + branch via the
  `sub` claim.
- Every resource is tagged `Project` / `Environment` / `ManagedBy` via each
  stack's deployment-file `tags:` block, which CloudFormation propagates to
  all taggable resources.

## Tearing down

Delete stacks in **reverse order** (09 → 00). `DBInstance` and `ImagesBucket`
are retained on stack deletion (`DeletionPolicy: Snapshot` / `Retain`) so you
won't lose data or an RDS snapshot by accident — clean those up manually if
you're done with the lab.
