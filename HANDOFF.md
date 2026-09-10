# Handoff — tearing down and re-spinning up the lab

Living doc for "I'm putting the lab down for a while and will restart it
later." Complements `README.md` (architecture, ongoing operation) — this
file is specifically the down/up procedure, with today's real values filled
in so future-you doesn't have to re-derive anything from CloudTrail again.

## Current known values (as of this teardown)

| Thing | Value |
|---|---|
| AWS account | `711387109786` |
| Region | `us-east-1` |
| Root stack | `photo-gallery-dev-root` (8 nested stacks under it) |
| Bootstrap stack (Git sync) | `md5-PhotoUploaderLab` |
| ECR stack (Git sync, persistent - never torn down) | deployed from `templates/ecr.yaml` / `deployments/ecr.yaml` |
| GitHub org | `thierry0011` |
| Infra repo | `md5-photo-uploader-infra` |
| App repo | `md5-photo-uploader-app` |
| Images bucket | `photo-gallery-dev-images-711387109786` |
| Access-logs bucket | `photo-gallery-dev-access-logs-711387109786` |
| Pipeline artifact bucket | `photo-gallery-dev-pipeline-artifacts-711387109786` |
| Templates bucket (bootstrap) | `photo-gallery-dev-cfn-templates-711387109786` |
| DB credentials secret | `photo-gallery-dev-db-credentials` |
| Django secret key (SSM SecureString, hand-created, persistent - never torn down, encrypted with the ECR key below, not the SecurityStack one) | `photo-gallery-dev-django-secret-key` |
| KMS alias (SecurityStack's shared CMK - ephemeral, torn down every cycle) | `alias/photo-gallery-dev` |
| KMS alias (ecr.yaml's dedicated CMK - persistent, never torn down) | `alias/photo-gallery-dev-ecr` |
| RDS instance identifier | `photo-gallery-dev-db` |

All of the above (except the KMS key's actual key ID, which is random) are
**deterministic names with no random suffix** — meaning if a resource is
left behind after a teardown, a respin's `CREATE` for that same logical
resource will fail with "already exists." That's the whole reason the
teardown script below does more than just `delete-stack`.

## Tearing down

### 1. Delete the root stack + its retained resources (scripted)

```bash
cd photo-uploader-infra
AWS_PROFILE=admin ./scripts/teardown.sh
```

This does, in order:
1. Empties `photo-gallery-dev-pipeline-artifacts-711387109786` first — it
   has no `DeletionPolicy` (so CloudFormation's default is to delete it),
   but it refuses to delete while non-empty, and it's non-empty by design
   at teardown time (CodePipeline writes to it on every deploy). A
   non-empty bucket makes its owning nested stack — and so the whole root
   stack — `DELETE_FAILED`. Pre-emptying it avoids the stuck-stack cycle
   entirely. (The ECR repository used to need this same treatment too,
   back when it was a nested stack under root - it isn't anymore. It now
   lives in the standalone, persistent `ecr.yaml` stack, which this script
   never touches at all - see "ECR stack - never touch this" below.)
2. `aws cloudformation delete-stack` on `photo-gallery-dev-root`, then
   waits for `DELETE_COMPLETE`. CloudFormation cascades all 8 nested
   stacks itself, in the correct dependency order — this is the "not
   manual" part; no per-resource deletion, no `full_sweep.py`-style
   orphan hunting.
3. Cleans up exactly what step 2 deliberately doesn't touch, because
   every one of these carries `DeletionPolicy: Retain` or `Snapshot` on
   purpose (so a *failed* deploy never destroys real data):
   - Force-deletes both Secrets Manager secrets (so a respin can recreate
     the same secret name immediately, instead of hitting "already
     scheduled for deletion").
   - Empties and deletes the images + access-logs S3 buckets.
   - Deletes the KMS alias (frees the name for a respin's new key) but
     leaves the underlying key pending — deleting a CMK is a 7–30 day
     wait no matter what, and a respin creates a brand-new key anyway.
     Pass `--schedule-key-deletion-days=7` if you want the old one to
     actually go away eventually instead of sitting pending forever
     (~$1/mo).
   - Finds and reports the RDS final snapshot CloudFormation created on
     `DBInstance` deletion, but **leaves it by default** — it's the only
     way to restore this lab's data if you ever want it back. Pass
     `--delete-snapshot` if you're sure you don't.

Flags: `--yes` skips the confirmation prompt, `--delete-snapshot` and
`--schedule-key-deletion-days=N` as above. Re-running the script is safe —
every step checks what's already gone before acting.

**Known caveat**: if a VPC endpoint gets stuck in `DELETE_IN_PROGRESS` with
an "UPDATE_PENDING is too recent" error, that's a real AWS timing race we
hit during this lab's own deploys, not a bug in the templates — wait
15–20 minutes and re-run the script.

**Known caveat — orphaned nested stacks after a retried delete.** We hit
this for real during this lab's own teardown (back when the ECR repository
was still a nested stack under root and could stall a delete the same way
the pipeline-artifacts bucket still can): a failed delete on one nested
stack, retried, can leave *other* nested stacks — we saw `SecurityStack`,
`NetworkStack`, `GithubOidcStack` — behind, alive, and disconnected from any
parent (`ParentId` empty), even though the root stack itself reaches
`DELETE_COMPLETE` successfully. This is a real CloudFormation quirk with
nested stacks + delete retries, not something the templates or the script
can prevent. Detect it after any teardown with:

```bash
aws cloudformation list-stacks --region us-east-1 \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query "StackSummaries[?contains(StackName, 'photo-gallery-dev-root-')].{Name:StackName,Parent:ParentId}" \
  --output table
```

Any row here after the root stack itself is gone is an orphan — delete
each directly by its exact (randomly-suffixed) name,
`SecurityStack` **before** `NetworkStack` (its security groups reference
the VPC, so the VPC can't delete first):

```bash
aws cloudformation delete-stack --region us-east-1 --stack-name <SecurityStack-exact-name>
aws cloudformation wait stack-delete-complete --region us-east-1 --stack-name <SecurityStack-exact-name>
aws cloudformation delete-stack --region us-east-1 --stack-name <NetworkStack-exact-name>
aws cloudformation delete-stack --region us-east-1 --stack-name <GithubOidcStack-exact-name>
```

`SecurityStack` carries the same `Retain`-policy `AppKmsKey`/alias as
before — the KMS cleanup in step 3 of the script still applies regardless
of whether `SecurityStack` died as part of the root or was cleaned up
separately like this.

### 2. ECR stack — never touch this, ever

The `ecr.yaml` stack is the one thing in this whole lab deliberately meant
to survive every teardown. It holds `photo-gallery-dev-app` (the actual
image history) and its own dedicated CMK — never the same key `01-security.yaml`
creates, on purpose, so scheduling that key's deletion (step 3 above) can
never take the ECR repo's images down with it. `scripts/teardown.sh` never
references this stack at all; there is nothing to do here on a normal
teardown. Only tear it down if you want a genuinely fresh image history too
(same disconnect-Git-sync-first, then delete-stack dance as the bootstrap
stack below), and know that doing so means the next respin needs the
one-time manual seed again (see README.md's "Bootstrapping the first
deploy") before `root.yaml` can create the ECS service.

### 3. Bootstrap stack — leave it, most of the time

`md5-PhotoUploaderLab` (from `bootstrap.yaml`) is **not** part of the
nested tree and the script above doesn't touch it on purpose. It only
holds the packaged-templates S3 bucket and `InfraDeployRole` — both cheap
to leave running indefinitely (a private S3 bucket and an IAM role cost
nothing at rest) and it's what makes the *next* respin a single `git push`
instead of another round of console setup. **Recommendation: don't delete
this unless you're permanently done with the lab.**

If you do want it gone too (it's Git-sync-managed, so there's no plain
`delete-stack` for it without also disconnecting the sync):
1. CloudFormation console → *Stacks* → `md5-PhotoUploaderLab` → the sync
   settings for this stack → remove/disconnect Git sync first (so the
   sync mechanism doesn't try to reconcile a stack you're about to
   delete out from under it).
2. Then delete the stack (console or
   `aws cloudformation delete-stack --stack-name md5-PhotoUploaderLab`).
3. Its `TemplatesBucket` (`photo-gallery-dev-cfn-templates-711387109786`)
   is also `Retain` — empty (it's not versioned, so a plain
   `aws s3 rm s3://<bucket> --recursive` is enough) and
   `aws s3api delete-bucket` it if you want it fully gone.
4. The GitHub OIDC provider (`token.actions.githubusercontent.com`) *and*
   `GitHubActionsEcrPushRole` (the app repo's CI role) both live here too
   now — deleting `md5-PhotoUploaderLab` removes both. This is also why
   `ecr.yaml` can never be deployed before `bootstrap.yaml`: it needs
   `GitHubActionsEcrPushRole` to already exist (see README.md's stack
   table). If you ever respin bootstrap fresh, set `CreateOidcProvider`
   back to `"true"` in `deployments/bootstrap.yaml` first.

## Spinning back up later

Same order as the very first deploy (see `README.md`'s "Deploying, in
order" for the full explanation) — condensed here as a literal checklist:

1. **Bootstrap** (skip entirely if you left it running per above).
   Console → *Stacks* → *Create stack* → *Sync from Git* → repo
   `md5-photo-uploader-infra`, deployment file `deployments/bootstrap.yaml`.
   One-time hand-created execution role (nothing exists yet to create it
   for you), scoped to what `bootstrap.yaml` itself creates.
2. **ECR** (skip entirely — this is the persistent one, it should already
   exist and still hold your last working image). Only redo this if you
   deliberately tore *it* down too: Console → *Create stack* → *Sync from
   Git* → deployment file `deployments/ecr.yaml`, using `InfraDeployRole`
   from step 1 as the execution role.
3. From bootstrap's outputs, set the infra repo's GitHub Actions secrets:
   `AWS_ROLE_ARN` ← `InfraDeployRoleArn`, `TEMPLATES_BUCKET` ←
   `TemplatesBucketName`. (Skip if these secrets are already set from
   before and bootstrap wasn't torn down.)
4. `ContainerImage` in `deployments/root.yaml` points at this account's own
   persistent ECR repo's `:latest` tag now, not the public `httpd`
   placeholder. If step 2 was a genuine first-ever `ecr.yaml` deploy (or you
   deliberately wiped the repo), `:latest` won't exist yet - seed it once,
   manually, before this step (see README.md's "Bootstrapping the first
   deploy" for the exact `docker pull`/`tag`/`push` commands). If ECR
   already survived from before, skip this - `:latest` is already there.
4a. **One-time manual step, only needed if you didn't keep the parameter
   from before**: create the Django secret key SSM parameter, using
   `ecr.yaml`'s own persistent key rather than `SecurityStack`'s (which
   doesn't exist yet at this point in the checklist, and is torn down every
   cycle anyway - see README.md's "Bootstrapping the first deploy" for the
   full reasoning):
   ```bash
   aws ssm put-parameter \
     --name photo-gallery-dev-django-secret-key \
     --type SecureString \
     --key-id alias/photo-gallery-dev-ecr \
     --value "$(openssl rand -base64 48 | tr -d '\n')"
   ```
   Skip this step entirely if the parameter already survived from before
   (it's never touched by `scripts/teardown.sh`, on purpose).
5. Push to `main` (or *Actions → Run workflow* on
   `deploy-root-stack.yml`) — packages + deploys `root.yaml` and all 8
   nested stacks in one job run. Expect 15–25 minutes. ECS starts directly
   on whatever `:latest` was at deploy time - no NAT Gateway needed for
   this pull, since it comes from your own repo through the existing VPC
   endpoints.
6. Put `bootstrap.yaml`'s `GitHubActionsRoleArn` output into the **app
   repo's** `build-and-push.yml` if it changed (it's a plain `env:` value
   there, not a secret — only update the committed file if the ARN is
   different from last time, e.g. after a full bootstrap re-creation - it
   normally won't be, since bootstrap is meant to survive). Push the app
   repo to `main` — this builds the real image, pushes to ECR, renders and
   uploads the deploy artifact to the pipeline's S3 bucket, and the
   resulting EventBridge → CodePipeline → CodeDeploy chain replaces
   whatever image was running with the actual Django app automatically. No
   CodeStar/CodeConnections handshake needed anymore - the pipeline's
   source is that S3 upload, not a GitHub connection.
7. Verify: `aws cloudformation describe-stacks --stack-name
   photo-gallery-dev-root --query "Stacks[0].Outputs"` for the ALB DNS
   name and CloudFront domain, then load the gallery in a browser.

If you deleted the RDS snapshot in teardown step 1, this respin creates a
brand-new empty database (fine for a lab). If you kept it and want the old
data back, `04-database.yaml` would need a `DBSnapshotIdentifier` parameter
threaded through to restore from it — not currently wired up, since the
lab has never needed it — flag it if you want that added before your next
teardown.
