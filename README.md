# Photo Gallery — Infrastructure (CloudFormation nested stacks)

Infrastructure-as-code for a highly available, containerized photo gallery on
ECS Fargate. A single **root stack** (`templates/root.yaml`) owns 10 **nested
stacks** (network, security, vpc-endpoints, storage-cdn, database, ecr,
github-oidc, ecs-alb, autoscaling, cicd-pipeline) as
`AWS::CloudFormation::Stack` resources, wired together with `!GetAtt`.

Two different deploy mechanisms are used, deliberately:
- **`bootstrap.yaml`** (one-time prerequisite, not part of the nested tree)
  is deployed via **AWS CloudFormation Git sync** — small, security-sensitive,
  rarely changes, benefits from the PR-review step Git sync gives you.
- **`root.yaml`** (the actual application infra) is deployed by
  `.github/workflows/deploy-root-stack.yml`: on every push touching
  `templates/root.yaml`, `templates/stacks/**`, or `deployments/root.yaml`,
  GitHub Actions packages the nested-stack templates to S3 and runs
  `aws cloudformation deploy` **in the same job run** — no intermediate file
  is ever committed anywhere. `aws cloudformation deploy` does its own
  changeset comparison against the live stack each time, so pushing
  unchanged templates is a no-op. Git sync isn't used here at all (see "Why
  root.yaml isn't Git-sync-deployed" below).

Application code lives in a separate repo: **md5-photo-uploader-app**.

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

## Source of truth

`templates/root.yaml` and `templates/stacks/*.yaml` are the only files you
ever edit for the nested stack. The packaged template (`aws cloudformation
package`'s output, with local `TemplateURL`s rewritten to real S3 URLs) is
written to `/tmp` inside the deploy workflow's run and used immediately —
it's never written into the repo, never committed, doesn't exist once the
job finishes. There is no generated file to accidentally hand-edit.

## Stack layout

| Stack | Template | Creates | Depends on (via `!GetAtt`) |
|---|---|---|---|
| — | `bootstrap.yaml` (standalone, **not nested**) | S3 bucket for packaged templates, `InfraDeployRole` (dual-trust: GitHub OIDC for this repo's deploy workflow + `cloudformation.amazonaws.com` as root's execution role) | — |
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
`templates/bootstrap.yaml` / `deployments/bootstrap.yaml`, deployed via Git
sync, create the S3 bucket that packaged templates get uploaded to, and
`InfraDeployRole` — the one role used for everything else from here on.
`bootstrap.yaml` is **not part of the nested-stack tree** — `root.yaml`
never supersedes, absorbs, or manages it.

**Phase 2 — the nested stack (ongoing).** Push a change to
`templates/root.yaml`, `templates/stacks/**`, or `deployments/root.yaml` →
`.github/workflows/deploy-root-stack.yml` assumes `InfraDeployRole` via
OIDC, packages `root.yaml` to a local, never-committed file, and runs
`aws cloudformation deploy` against it in that same job — creating or
updating the root stack and its 10 nested children in one pass.

## Why root.yaml isn't Git-sync-deployed

Two independent reasons converged on this design:

1. CloudFormation Git sync deploys exactly the one template file named in a
   deployment file's `template-file-path` — it has no mechanism to resolve a
   nested stack's `TemplateURL` from a relative path elsewhere in the repo.
   `AWS::CloudFormation::Stack` requires `TemplateURL` to already be a real
   `https://` S3 URL, so *something* has to package local templates to S3
   before any deploy mechanism can see the parent template.
2. The packaged template is a build artifact, not something we want sitting
   in git history at all — not even on a side branch. So instead of
   packaging once and committing the result for Git sync to pick up later,
   the same job that packages it also deploys it immediately, and the file
   never outlives that job.

`InfraDeployRole`'s trust policy reflects this directly: one statement lets
GitHub Actions assume it via OIDC (to call `aws cloudformation deploy`), a
second lets `cloudformation.amazonaws.com` assume the *same* role (as the
execution role that actually provisions every resource in the 10 nested
stacks) — one role, two callers, no separate execution role to create by
hand.

## One-time prerequisites (console, unavoidable manual steps)

Git sync (for `bootstrap.yaml`) and CodePipeline's GitHub source (in
`CicdPipelineStack`) both rely on **AWS CodeConnections**, which requires a
one-time interactive OAuth handshake — this cannot be scripted or done via
CloudFormation itself.

1. **Link this repo for Git sync**: CloudFormation console → *Stacks* →
   *Create stack* → *With new resources* → *Sync from Git* → *Link a Git
   repository* → GitHub → authorize AWS's GitHub App for this repo. (Only
   needed for `bootstrap.yaml` — `root.yaml` doesn't use Git sync.)
2. **Authorize the application repo's connection**: after `CicdPipelineStack`
   is created, open **Developer Tools → Connections** in the console once
   and click **Update pending connection** on the connection named in the
   root stack's `AppRepoConnectionArn` output (`md5-photo-uploader-app`).

## Deploying, in order

1. **Deploy `bootstrap.yaml`** via Git sync: *Create stack* → *Sync from
   Git* → deployment file `deployments/bootstrap.yaml`, template file
   `templates/bootstrap.yaml`. Fill in `GitHubOrg` with your real GitHub
   org/username first. This stack still needs its own one-time execution
   role, created by hand (console *Create role*, since nothing exists yet to
   create it for you) — scoped narrowly to just what `bootstrap.yaml`
   itself creates (S3 bucket + IAM role/OIDC provider).
2. From `bootstrap.yaml`'s outputs, add two **repository secrets** (Settings
   → Secrets and variables → Actions): `AWS_ROLE_ARN` ← `InfraDeployRoleArn`,
   `TEMPLATES_BUCKET` ← `TemplatesBucketName`.
3. Push to `main` (or run `deploy-root-stack.yml` manually via
   *Actions → Run workflow*) — this packages and deploys the root stack plus
   all 10 nested children in one run. Fill in `GitHubOrg` / `GitHubAppRepo`
   in `deployments/root.yaml` first if they differ from the defaults.
4. Complete the CodeConnections handshake for the app repo (see above).
5. Put the root stack's `GitHubActionsRoleArn` output into the app repo's
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
`ContainerImage`, `TaskCpu`). The deploy workflow would re-run
`aws cloudformation deploy` on the root stack (and thus this nested stack),
and CloudFormation would try to reconcile the service back to the stack's
last-known state (the placeholder image), fighting CodeDeploy. Safe, ongoing changes belong in the app repo
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
- **CI/CD uses OIDC** (`stacks/06-github-oidc.yaml`'s role for the app
  repo's build-and-push workflow, `bootstrap.yaml`'s `InfraDeployRole` for
  this repo's deploy workflow) — no long-lived AWS credentials anywhere,
  each role scoped to one repo + branch via the `sub` claim.
- Every resource is tagged `Project` / `Environment` / `ManagedBy` via
  `deployments/root.yaml`'s `tags:` block, which `deploy-root-stack.yml`
  passes to `aws cloudformation deploy --tags` and which nested stacks then
  inherit from the root stack automatically.

## Tearing down

There's no Git-sync PR to merge for a root-stack deletion since it isn't
Git-sync-managed — delete it directly:

```bash
aws cloudformation delete-stack --stack-name photo-gallery-dev-root
```

CloudFormation deletes all 10 nested stacks for you, in reverse dependency
order. `DBInstance` and `ImagesBucket` (and a few others — see each
template's `DeletionPolicy`) are retained on deletion (`Snapshot` /
`Retain`) so you won't lose data or an RDS snapshot by accident — clean
those up manually if you're done with the lab. Delete `bootstrap.yaml`'s
stack (still Git-sync-managed, so via the console or a PR that removes it)
separately, last, once you're sure you won't need to deploy the nested tree
again.
