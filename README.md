# Photo Gallery — Infrastructure (CloudFormation nested stacks)

Infrastructure-as-code for a highly available, containerized photo gallery on
ECS Fargate. A single **root stack** (`templates/root.yaml`) owns 9 **nested
stacks** (network, security, vpc-endpoints, storage-cdn, database,
github-oidc, ecs-alb, autoscaling, cicd-pipeline) as
`AWS::CloudFormation::Stack` resources, wired together with `!GetAtt`.

Three different deploy mechanisms are used, deliberately:
- **`bootstrap.yaml`** (one-time prerequisite, not part of the nested tree)
  is deployed via **AWS CloudFormation Git sync** — small, security-sensitive,
  rarely changes, benefits from the PR-review step Git sync gives you.
- **`ecr.yaml`** (the app's ECR repository, also not part of the nested tree)
  is likewise deployed via **Git sync**, standalone, and — unlike everything
  under `root.yaml` — is never torn down: it's the one piece of application
  state meant to survive a full teardown/respin cycle, so the last working
  image doesn't have to be rebuilt from scratch every time. See that
  template's own Description for the full reasoning (including why it uses
  its own dedicated KMS key instead of the shared one).
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
              └─ Green target group (no listener - CodeDeploy shifts :80
                                      between blue/green directly)
                       │
                       ▼
              RDS PostgreSQL (dedicated private subnets, 2 AZ, db.t3)

No NAT Gateway by default — ECS tasks reach ECR, S3, CloudWatch Logs and
Secrets Manager entirely through VPC interface/gateway endpoints.

ECR push ──▶ EventBridge rule ──▶ CodePipeline ──▶ CodeDeploy (blue/green) ──▶ ECS
```

Diagram-as-code source lives under [`diagrams/`](diagrams/) (`diagrams` /
mingrammer, standard AWS icons throughout):

- [`architecture_diagram.py`](diagrams/architecture_diagram.py) — the
  overall static architecture (above).
- [`cicd_push_flow_diagram.py`](diagrams/cicd_push_flow_diagram.py) — what
  happens when a developer pushes app code: GitHub Actions → OIDC → ECR
  push + render/upload deploy artifact to S3 → EventBridge (on the S3
  write) → CodePipeline → CodeDeploy blue/green.
- [`infra_push_flow_diagram.py`](diagrams/infra_push_flow_diagram.py) — what
  happens when a developer pushes infra code: GitHub Actions → OIDC →
  package to S3 → `aws cloudformation deploy` → root.yaml's 8 nested
  stacks, versus the separate one-time Git sync path for `bootstrap.yaml`
  and `ecr.yaml`.
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
python infra_push_flow_diagram.py                    # -> infra_push_flow.png
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
| — | `ecr.yaml` (standalone, **not nested**, survives teardown) | ECR repository for the app image, its own dedicated KMS CMK, `GitHubActionsEcrPushRole` (OIDC role the **app repo's** CI assumes to push images to ECR and upload deploy artifacts) and the repo policy trusting it | — (role is defined in this same template, no cross-stack reference needed) |
| `NetworkStack` | `stacks/00-network.yaml` | VPC, public/private subnets (2 AZ) plus a dedicated RDS-only private tier (2 AZ), routing, S3 gateway endpoint | — |
| `SecurityStack` | `stacks/01-security.yaml` | Security groups, shared KMS CMK | Network |
| `VpcEndpointsStack` | `stacks/02-vpc-endpoints.yaml` | Interface endpoints: ECR api/dkr, CloudWatch Logs, Secrets Manager | Network, Security |
| `StorageCdnStack` | `stacks/03-storage-cdn.yaml` | S3 image bucket, CloudFront + OAC, access-logs bucket | Security |
| `DatabaseStack` | `stacks/04-database.yaml` | RDS PostgreSQL, Secrets Manager credentials | Network, Security |
| `EcsAlbStack` | `stacks/07-ecs-alb.yaml` | ALB (2 target groups, 1 listener), ECS cluster/service/task def | Network, Security, StorageCdn, Database, plus `ecr.yaml`'s `EcrKmsKeyArn` export (`Fn::ImportValue`, to decrypt the Django secret key parameter) |
| `AutoscalingStack` | `stacks/08-autoscaling.yaml` | Application Auto Scaling (1–4 tasks, CPU target tracking) | EcsAlb |
| `CicdPipelineStack` | `stacks/09-cicd-pipeline.yaml` | S3 artifact bucket, CodePipeline, CodeDeploy blue/green, EventBridge trigger (fires on the app repo's S3 artifact upload, not an ECR push) | Security, EcsAlb, plus `ecr.yaml`'s `GitHubActionsRoleArn` export (`Fn::ImportValue`, granted write access to the artifact bucket) |

The GitHub Actions push role lives in `ecr.yaml` — not in this nested tree,
and not in `bootstrap.yaml` either — because it's only ever used by that
template's own `RepositoryPolicyText`; defining it there lets CloudFormation
resolve the dependency intra-stack (no cross-stack reference, no pasted
literal) while still keeping it out of `root.yaml`, which is the thing that
actually matters: `root.yaml`'s `EcsAlbStack` needs `ecr.yaml`'s KMS key
export, so if the role lived in `root.yaml` instead, `ecr.yaml` (which needs
the role to exist first) and `root.yaml` would depend on each other. Deploy
order is strictly `bootstrap.yaml` → `ecr.yaml` → `root.yaml`, always.

## Three-phase deploy lifecycle

**Phase 1 — bootstrap (one-time, standalone, do this first).**
`templates/bootstrap.yaml` / `deployments/bootstrap.yaml`, deployed via Git
sync, create the S3 bucket that packaged templates get uploaded to, and
`InfraDeployRole` — the one role used for everything else from here on.
`bootstrap.yaml` is **not part of the nested-stack tree** — `root.yaml`
never supersedes, absorbs, or manages it.

**Phase 2 — the ECR repository (one-time, standalone, deploy once and leave
running).** `templates/ecr.yaml` / `deployments/ecr.yaml`, also deployed via
Git sync using `InfraDeployRole` as its execution role. Creates the ECR
repository, its own dedicated CMK, and `GitHubActionsEcrPushRole` (the app
repo's CI push role — co-located here since it's only ever granted access in
this template's own repository policy). Unlike everything in Phase 3, this
is never torn down between respins — it's the one piece of application
state deliberately meant to survive a full teardown, so the last working
app image is still there the next time you spin the lab back up. See that
template's Description for why it uses its own dedicated CMK.

**Phase 3 — the nested stack (ongoing, fully disposable).** Push a change to
`templates/root.yaml`, `templates/stacks/**`, or `deployments/root.yaml` →
`.github/workflows/deploy-root-stack.yml` assumes `InfraDeployRole` via
OIDC, packages `root.yaml` to a local, never-committed file, and runs
`aws cloudformation deploy` against it in that same job — creating or
updating the root stack and its 8 nested children in one pass.

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
execution role that actually provisions every resource in the 8 nested
stacks, and also `ecr.yaml`'s Git-sync-managed resources) — one role, two
callers, no separate execution role to create by hand.

## One-time prerequisites (console, unavoidable manual steps)

Git sync (for `bootstrap.yaml` and `ecr.yaml`) relies on **AWS
CodeConnections**, which requires a one-time interactive OAuth handshake —
this cannot be scripted or done via CloudFormation itself.

1. **Link this repo for Git sync**: CloudFormation console → *Stacks* →
   *Create stack* → *With new resources* → *Sync from Git* → *Link a Git
   repository* → GitHub → authorize AWS's GitHub App for this repo. Only
   needed once, for `bootstrap.yaml` and `ecr.yaml` — `root.yaml` doesn't
   use Git sync, and `CicdPipelineStack`'s pipeline is triggered by an S3
   upload from the app repo's own CI, not a GitHub connection — nothing in
   this project's deploy pipeline talks to GitHub via CodeConnections.

## Deploying, in order

1. **Deploy `bootstrap.yaml`** via Git sync: *Create stack* → *Sync from
   Git* → deployment file `deployments/bootstrap.yaml`, template file
   `templates/bootstrap.yaml`. Fill in `GitHubOrg` with your real GitHub
   org/username first. This stack still needs its own one-time execution
   role, created by hand (console *Create role*, since nothing exists yet to
   create it for you) — scoped narrowly to just what `bootstrap.yaml`
   itself creates (S3 bucket + IAM roles/OIDC provider).
2. **Deploy `ecr.yaml`** via Git sync the same way, deployment file
   `deployments/ecr.yaml`, using `InfraDeployRole` (from step 1) as its
   execution role — no new role needed, its existing ECR/KMS/IAM permissions
   already cover this. Fill in `GitHubOrg` (and `GitHubAppRepo` if it's not
   `md5-photo-uploader-app`) first — this template now creates
   `GitHubActionsEcrPushRole` itself, so it needs those directly rather than
   an ARN passed in from `bootstrap.yaml`. Do this **once** — never delete
   this stack as part of a normal teardown/respin.

   With `ecr.yaml` deployed, do the two other one-time manual steps now,
   before moving on - both only need this stack, not `root.yaml` (see
   "Bootstrapping the first deploy" below for the full reasoning and exact
   commands): seed the ECR repo with a placeholder `:latest` image, and
   create the `photo-gallery-dev-django-secret-key` SSM SecureString
   parameter (encrypted with this stack's `EcrKmsKey`, alias
   `alias/photo-gallery-dev-ecr`).
3. From `bootstrap.yaml`'s outputs, add two **repository secrets** (Settings
   → Secrets and variables → Actions): `AWS_ROLE_ARN` ← `InfraDeployRoleArn`,
   `TEMPLATES_BUCKET` ← `TemplatesBucketName`. From `ecr.yaml`'s outputs, fill
   `EcrRepositoryArn` into `deployments/root.yaml`.
4. Push to `main` (or run `deploy-root-stack.yml` manually via
   *Actions → Run workflow*) — this packages and deploys the root stack plus
   its 8 nested children in one run. `GitHubActionsRoleArn` is no longer a
   parameter anywhere in this tree — `root.yaml` resolves it via
   `Fn::ImportValue` against `ecr.yaml`'s export directly.
5. In the **app repo's** GitHub Settings → Secrets and variables → Actions,
   add three **repository secrets**: `AWS_ROLE_ARN` ← `ecr.yaml`'s
   `GitHubActionsRoleArn` output, `TASK_EXECUTION_ROLE_ARN` and
   `TASK_ROLE_ARN` ← `EcsAlbStack`'s outputs of the same name (visible under
   `root.yaml`'s nested stack resources). These used to be plain `env:`
   values / live CloudFormation lookups in the app repo's workflow; they're
   secrets now so the workflow doesn't carry account-specific ARNs in
   committed YAML.

On any later respin, only steps 4–5 repeat — `bootstrap.yaml` and
`ecr.yaml` are both one-time, standalone, and untouched by
`scripts/teardown.sh`.

## Bootstrapping the first deploy

`ContainerImage` in `deployments/root.yaml` points at this account's own
persistent ECR repo (`templates/ecr.yaml`), not a public placeholder - that
repo survives every teardown/respin, so on any respin after the first real
push, ECS just starts on the last working image directly. No NAT Gateway
needed for this pull: it comes from your own repo, reachable through the
`ecr.api`/`ecr.dkr` VPC endpoints alone.

The one exception is a genuinely first-ever cold start - `ecr.yaml` just
deployed, nothing pushed to it yet, `:latest` doesn't exist. `root.yaml`
would fail to create the ECS service pointing at a tag that isn't there.
Seed it once, manually, before deploying `root.yaml` for the very first
time (from a machine with internet access - this pull, unlike the task's,
isn't going through any VPC endpoint at all):

```bash
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin 711387109786.dkr.ecr.us-east-1.amazonaws.com

docker pull public.ecr.aws/docker/library/httpd:2.4
docker tag public.ecr.aws/docker/library/httpd:2.4 \
  711387109786.dkr.ecr.us-east-1.amazonaws.com/photo-gallery-dev-app:latest
docker push 711387109786.dkr.ecr.us-east-1.amazonaws.com/photo-gallery-dev-app:latest
```

While `ecr.yaml` is freshly deployed and you're already doing one manual
one-time step, do the other one too: `AppTaskDefinition`'s
`DJANGO_SECRET_KEY` needs a `photo-gallery-dev-django-secret-key` SSM
SecureString parameter, and `AWS::SSM::Parameter` can't create a
`SecureString` in CloudFormation (only plaintext `String`/`StringList`), so
unlike the DB credentials this one isn't generated by any stack:

```bash
aws ssm put-parameter \
  --name photo-gallery-dev-django-secret-key \
  --type SecureString \
  --key-id alias/photo-gallery-dev-ecr \
  --value "$(openssl rand -base64 48 | tr -d '\n')"
```

`--key-id` must be `ecr.yaml`'s own persistent `EcrKmsKey`
(`alias/photo-gallery-dev-ecr`), **not** `stacks/01-security.yaml`'s
`AppKmsKey` (`alias/photo-gallery-dev`) - that one lives inside
`SecurityStack`, torn down and recreated every teardown/respin cycle. Using
it here would deadlock `root.yaml`'s very first-ever deploy: the ECS task
can't resolve the secret until the parameter exists, the parameter can't be
created until the (ephemeral) key exists, and the key doesn't exist until
`root.yaml` finishes deploying - which it never does, because the ECS
service that's blocking on the secret is itself part of that same deploy,
and a first-deploy failure in any nested stack rolls the whole thing back
(see "Failure / rollback behavior" below), taking `SecurityStack` and its
key with it. `EcrKmsKey` sidesteps this entirely: it exists before
`root.yaml` is ever deployed, same as the image seed above, and
`TaskExecutionRole` in `stacks/07-ecs-alb.yaml` is granted `kms:Decrypt` on
it via a cross-stack `Fn::ImportValue` (see `ecr.yaml`'s `EcrKmsKeyArn`
output and that role's `ReadSsmParameters` policy). It's also the
semantically correct choice regardless of the deploy-order issue: a value
meant to survive every teardown (like the ECR image) needs a key that also
survives every teardown, not the ephemeral one.

Survives every teardown (`scripts/teardown.sh` never touches it, on purpose,
same as the ECR repo) - only redo this if you deliberately delete the
parameter itself.

After both one-time steps above, deploy `root.yaml` as normal. Once:

1. The application repo's GitHub Actions workflow has pushed at least one
   real image tagged `latest` to ECR, and
2. `CicdPipelineStack` exists,

the EventBridge rule fires automatically and CodeDeploy performs a real
blue/green deployment, replacing whatever was there with your Django app.

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

- **No NAT Gateway, period.** ECS tasks never need general internet egress —
  ECR, S3, CloudWatch Logs and Secrets Manager are all reached via VPC
  endpoints. Saves ~$32/mo per AZ plus data processing charges. There's no
  toggle for this anymore (it briefly existed, see git history on
  `00-network.yaml` if a future respin ever needs one back) — if the app
  someday needs arbitrary outbound internet access, add a NAT Gateway back
  in deliberately rather than flip a flag.
- **RDS Multi-AZ is on** (`DBMultiAZ: "true"`) — a standby replica in the
  second AZ with automatic failover, roughly doubling DB cost, but without
  it the database is a single point of failure in one AZ while every other
  tier (ALB, ECS, NAT) is genuinely spread across both - inconsistent with
  the "highly available" requirement. Flip to `"false"` only if minimizing
  cost matters more than that for a given run.
- **RDS sits in its own dedicated private subnet tier** (`PrivateDbSubnet1/2`,
  `10.20.20.0/24` / `10.20.21.0/24`), separate from the ECS private subnets
  (`PrivateSubnet1/2`, `10.20.10.0/24` / `10.20.11.0/24`). Blast-radius
  isolation only — the RDS security group already restricts inbound to the
  ECS security group regardless of subnet, so this doesn't change reachability,
  just keeps the DB off the same subnet as anything else that ever lands in
  the app tier.
- **S3 bucket is fully private**; CloudFront reads it only via Origin Access
  Control scoped to this exact distribution ARN (`AWS:SourceArn` condition).
- **All data at rest is KMS-encrypted** with a single rotated CMK (S3, RDS,
  Secrets Manager, ECR, CloudWatch Logs).
- **CI/CD uses OIDC** (`ecr.yaml`'s `GitHubActionsEcrPushRole` for the app
  repo's build-and-push workflow, `bootstrap.yaml`'s `InfraDeployRole` for
  this repo's deploy workflow) — no long-lived AWS credentials anywhere,
  each role scoped to one repo + branch via the `sub` claim.
- Every resource is tagged `Project` / `Environment` / `ManagedBy` via
  `deployments/root.yaml`'s `tags:` block, which `deploy-root-stack.yml`
  passes to `aws cloudformation deploy --tags` and which nested stacks then
  inherit from the root stack automatically.

## Tearing down / spinning back up later

See [`HANDOFF.md`](HANDOFF.md) — the full down/up runbook, with today's
actual resource names filled in (no re-deriving anything from CloudTrail
next time) and `scripts/teardown.sh`, which deletes the root stack (cascades
all 8 nested stacks automatically) and then cleans up exactly the handful
of resources their `Retain`/`Snapshot` `DeletionPolicy`s deliberately leave
behind — no manual per-resource hunting. `bootstrap.yaml` and `ecr.yaml` are
both untouched by the script on purpose — see "Three-phase deploy lifecycle"
above.
