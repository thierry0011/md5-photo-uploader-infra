# Photo Gallery — Infrastructure (CloudFormation, nested stacks + Git Sync)

Infrastructure-as-code for a highly available, containerized photo gallery on
ECS Fargate. This repo is deployed via **AWS CloudFormation Git sync** — no
`aws cloudformation deploy` from a laptop, no Terraform, no CDK. A single
**root stack** (`templates/root.yaml`) owns 10 **nested stacks** (network,
security, vpc-endpoints, storage-cdn, database, ecr, github-oidc, ecs-alb,
autoscaling, cicd-pipeline) as `AWS::CloudFormation::Stack` resources, wired
together with `!GetAtt`. Pushing a change to `templates/root.yaml` or
`templates/stacks/**` re-deploys the whole nested tree automatically (via a
GitHub Actions packaging step, then a pull request CloudFormation opens on
this repo for Git sync — see "How deploys actually happen" below).

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

Diagram-as-code source lives under [`diagrams/`](diagrams/) (`diagrams` /
mingrammer, standard AWS icons throughout):

- [`architecture_diagram.py`](diagrams/architecture_diagram.py) — the
  overall static architecture (above).
- [`cicd_push_flow_diagram.py`](diagrams/cicd_push_flow_diagram.py) — what
  happens when a developer pushes app code: GitHub Actions → OIDC → ECR →
  EventBridge → CodePipeline → CodeDeploy blue/green.
- [`user_upload_flow_diagram.py`](diagrams/user_upload_flow_diagram.py) —
  what happens when a visitor loads the gallery and uploads a photo (traced
  from the actual Django view/form code: upload goes through Django/boto3
  to S3, not a browser-side presigned URL).

Render any of them with:

```bash
pip install diagrams
# install the Graphviz `dot` binary for your OS (brew/apt/choco install graphviz)
cd diagrams && python architecture_diagram.py       # -> architecture.png
python cicd_push_flow_diagram.py                     # -> cicd_push_flow.png
python user_upload_flow_diagram.py                   # -> user_upload_flow.png
```

## Source of truth vs. generated artifact

- **`templates/root.yaml`** and **`templates/stacks/*.yaml`** are the
  source of truth. Edit these.
- **`templates/root.packaged.yaml`** is a **generated build artifact**,
  produced by `.github/workflows/package-templates.yml` and committed back
  to `main` automatically. It exists only because CloudFormation Git sync
  can watch just the files that live in the repo, and a nested stack's
  `TemplateURL` must already be a real S3 URL by the time Git sync reads it
  (see "Why the packaging step exists" below). **Never hand-edit
  `root.packaged.yaml`** — it carries an auto-generated header comment for
  exactly this reason, and any manual edit is silently overwritten on the
  next push to `main`.

## Stack layout

| Stack | Template | Creates | Depends on (via `!GetAtt`) |
|---|---|---|---|
| — | `bootstrap.yaml` (standalone, **not nested**) | S3 bucket for packaged templates, GitHub Actions OIDC role for *this* repo | — |
| `NetworkStack` | `stacks/00-network.yaml` | VPC, public/private subnets (2 AZ), routing, S3 gateway endpoint | — |
| `SecurityStack` | `stacks/01-security.yaml` | Security groups, shared KMS CMK | Network |
| `VpcEndpointsStack` | `stacks/02-vpc-endpoints.yaml` | Interface endpoints: ECR api/dkr, CloudWatch Logs, Secrets Manager | Network, Security |
| `StorageCdnStack` | `stacks/03-storage-cdn.yaml` | S3 image bucket, CloudFront + OAC, access-logs bucket | Security |
| `DatabaseStack` | `stacks/04-database.yaml` | RDS PostgreSQL, Secrets Manager credentials | Network, Security |
| `GithubOidcStack` | `stacks/06-github-oidc.yaml` | GitHub OIDC provider + role for app CI | — |
| `EcrStack` | `stacks/05-ecr.yaml` | ECR repository for the app image, repo policy trusting the OIDC role | Security, GithubOidc |
| `EcsAlbStack` | `stacks/07-ecs-alb.yaml` | ALB (2 target groups, 2 listeners), ECS cluster/service/task def | Network, Security, StorageCdn, Database |
| `AutoscalingStack` | `stacks/08-autoscaling.yaml` | Application Auto Scaling (1–4 tasks, CPU target tracking) | EcsAlb |
| `CicdPipelineStack` | `stacks/09-cicd-pipeline.yaml` | CodeStar connection, CodePipeline, CodeDeploy blue/green, EventBridge trigger | Security, Ecr, EcsAlb |

`GithubOidcStack` and `EcrStack` are listed out of numeric order because
that's the real dependency direction: `EcrStack`'s repository policy needs
`GithubOidcStack`'s role ARN. Deliberately one-directional — see the
comments at the top of `stacks/05-ecr.yaml` and `stacks/06-github-oidc.yaml`
for why (this used to be a genuine circular dependency in the old flat-stack
design, requiring a manual two-deploy dance; nested-stack ordering fixes it
for real instead of just relocating the hack).

## Two-phase deploy lifecycle

**Phase 1 — bootstrap (one-time, standalone, do this first).**
`templates/bootstrap.yaml` / `deployments/bootstrap.yaml` create the S3
bucket that packaged templates get uploaded to, and the GitHub Actions OIDC
role (for *this* repo) allowed to upload to it. `bootstrap.yaml` is **not
part of the nested-stack tree** — `root.yaml` never supersedes, absorbs, or
manages it.

**Phase 2 — the nested stack (ongoing).** Push a change to
`templates/root.yaml` or `templates/stacks/**` → GitHub Actions packages
`root.yaml` into `root.packaged.yaml` (rewriting local `TemplateURL`s to
real S3 URLs) and commits it back to `main` → Git sync (configured on
`deployments/root.yaml`, watching `templates/root.packaged.yaml`) deploys or
updates the root stack and its 10 nested children.

## Why the packaging step exists

CloudFormation Git sync deploys exactly the one template file named in a
deployment file's `template-file-path` — it has no mechanism to resolve a
nested stack's `TemplateURL` from a relative path elsewhere in the repo.
`AWS::CloudFormation::Stack` requires `TemplateURL` to already be a real
`https://` S3 URL. So child templates have to be packaged/uploaded to S3
*before* Git sync ever sees the parent template — that's what the packaging
workflow and `bootstrap.yaml`'s S3 bucket are for.

## One-time prerequisites (console, unavoidable manual steps)

CloudFormation Git sync and CodePipeline's GitHub source both rely on **AWS
CodeConnections**, which requires a one-time interactive OAuth handshake —
this cannot be scripted or done via CloudFormation itself.

1. **Link this repo for Git sync**: CloudFormation console → *Stacks* →
   *Create stack* → *With new resources* → *Sync from Git* → *Link a Git
   repository* → GitHub → authorize AWS's GitHub App for this repo.
2. **Authorize the application repo's connection**: after `CicdPipelineStack`
   is created, open **Developer Tools → Connections** in the console once
   and click **Update pending connection** on the connection named in the
   root stack's `AppRepoConnectionArn` output (`photo-uploader-app`).

## Deploying, in order

1. **Deploy `bootstrap.yaml`** via Git sync: *Create stack* → *Sync from
   Git* → deployment file `deployments/bootstrap.yaml`, template file
   `templates/bootstrap.yaml`. Fill in `GitHubOrg` with your real GitHub
   org/username first.
2. From `bootstrap.yaml`'s outputs, fill in the `<AWS_ACCOUNT_ID>`
   placeholders in `.github/workflows/package-templates.yml`
   (`AWS_ROLE_ARN` ← `InfraGitHubActionsRoleArn`, `TEMPLATES_BUCKET` ←
   `TemplatesBucketName`) and push.
3. Push to `main` (or run the workflow manually) so
   `templates/root.packaged.yaml` gets created by CI.
4. **Deploy the root stack** via Git sync: deployment file
   `deployments/root.yaml`, template file `templates/root.packaged.yaml`
   (not `root.yaml` — see "Source of truth vs. generated artifact"). Fill in
   `GitHubOrg` / `GitHubAppRepo` in `deployments/root.yaml` first if they
   differ from the defaults.
5. Complete the CodeConnections handshake for the app repo (see above).
6. Put the root stack's `GitHubActionsRoleArn` output into the app repo's
   `.github/workflows/build-and-push.yml` as `AWS_ROLE_ARN`.

Unlike the old flat-stack design, there's no manual "redeploy 05 with 06's
role ARN pasted in" step anymore — nested-stack ordering resolves that
dependency automatically on every deploy.

## Bootstrapping the first deploy

`07-ecs-alb.yaml` starts the ECS service on a placeholder image
(`public.ecr.aws/docker/library/httpd:2.4`) so the service has something
valid to run before your app image exists. Once:

1. The application repo's GitHub Actions workflow has pushed at least one
   image tagged `latest` to ECR, and
2. `CicdPipelineStack` exists,

the EventBridge rule fires automatically and CodeDeploy performs the first
real blue/green deployment, replacing the placeholder with your Django app.

## Getting the ALB endpoint

Nested-stack outputs aren't exported, so `list-exports` won't show them —
read the root stack's own outputs instead:

```bash
aws cloudformation describe-stacks \
  --stack-name photo-gallery-dev-root \
  --query "Stacks[0].Outputs[?OutputKey=='AlbDnsName'].OutputValue" --output text
```

## A known caveat of ECS + CodeDeploy blue/green under CloudFormation

Once CodeDeploy performs its first blue/green swap, it registers new task
definition revisions and re-points the ECS service outside CloudFormation's
knowledge — this is normal and how every ECS+CodeDeploy blue/green reference
architecture works. The consequence: after go-live, avoid pushing changes to
`stacks/07-ecs-alb.yaml` that touch `AppTaskDefinition` / `AppService` (e.g.
`ContainerImage`, `TaskCpu`). Git sync would re-run `UpdateStack` on the root
(and thus this nested stack), and CloudFormation would try to reconcile the
service back to the stack's last-known state (the placeholder image),
fighting CodeDeploy. Safe, ongoing changes belong in the app repo
(`ecs/taskdef.json` + `ecs/appspec.yaml`) or in `stacks/08-autoscaling.yaml`
/ `stacks/09-cicd-pipeline.yaml`, which don't touch the service's running
task definition directly.

## Failure / rollback behavior

Nesting changes blast radius versus the old flat, independently-deployed
stacks. On the **first** deploy, a failure in any one nested stack rolls
back the whole root operation, including sibling stacks that had already
succeeded. On later **updates**, only the nested stacks actually touched by
that update are rolled back. Stateful resources (KMS key, S3 buckets, DB
secret, RDS instance) already carry `Retain`/`Snapshot` `DeletionPolicy`s
and are unaffected by root-stack rollback or deletion.

## Cost / security choices worth knowing about

- **No NAT Gateway by default** (`EnableNatGateway: "false"`). ECS tasks
  never need general internet egress — ECR, S3, CloudWatch Logs and Secrets
  Manager are all reached via VPC endpoints. Saves ~$32/mo per AZ plus data
  processing charges. Flip to `"true"` in `deployments/root.yaml` if the app
  ever needs outbound internet access.
- **RDS Multi-AZ is off by default** (`DBMultiAZ: "false"`) — the VPC itself
  is Multi-AZ (subnets in 2 AZs) per the requirement, but a standby RDS
  replica roughly doubles DB cost. Flip on for a real production posture.
- **S3 bucket is fully private**; CloudFront reads it only via Origin Access
  Control scoped to this exact distribution ARN (`AWS:SourceArn` condition).
- **All data at rest is KMS-encrypted** with a single rotated CMK (S3, RDS,
  Secrets Manager, ECR, CloudWatch Logs).
- **CI/CD uses OIDC** (`stacks/06-github-oidc.yaml` for the app repo,
  `bootstrap.yaml` for this repo) — no long-lived AWS credentials anywhere,
  each role scoped to one repo + branch via the `sub` claim.
- Every resource is tagged `Project` / `Environment` / `ManagedBy` via
  `deployments/root.yaml`'s `tags:` block, which nested stacks inherit from
  the root stack automatically.

## Tearing down

Delete the root stack — CloudFormation deletes all 10 nested stacks for you,
in reverse dependency order. `DBInstance` and `ImagesBucket` (and a few
others — see each template's `DeletionPolicy`) are retained on deletion
(`Snapshot` / `Retain`) so you won't lose data or an RDS snapshot by
accident — clean those up manually if you're done with the lab. Delete
`bootstrap.yaml`'s stack separately, last, once you're sure you won't need
to re-package and re-deploy the nested tree again.
