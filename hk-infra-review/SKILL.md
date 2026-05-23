---
name: hk-infra-review
description: "[v1.0.0] Review GCP infrastructure and Terraform code for security, cost, reliability, and CI/CD best practices."
metadata:
  version: "1.0.0"
  source: "healthkey"
---

# Infra Review

## Preamble

```bash
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
echo "BRANCH: $BRANCH"

BASE="dev"
if git rev-parse --verify origin/dev >/dev/null 2>&1; then
  BASE="dev"
elif git rev-parse --verify origin/main >/dev/null 2>&1; then
  BASE="main"
fi
echo "BASE: $BASE"

# Check for .tf changes
TF_DIFF=$(git diff "$BASE"..."$BRANCH" --name-only -- '*.tf' '*.tfvars' 2>/dev/null || echo "")
TF_DIFF_STAT=$(git diff "$BASE"..."$BRANCH" --stat -- '*.tf' '*.tfvars' 2>/dev/null || echo "")

if [ -z "$TF_DIFF" ]; then
  echo "TF_DIFF: none"
else
  echo "TF_DIFF: found"
  echo "$TF_DIFF"
  echo "---"
  echo "$TF_DIFF_STAT"
fi

# Also check for workflow changes that touch infra
CI_DIFF=$(git diff "$BASE"..."$BRANCH" --name-only -- '.github/workflows/*terraform*' '.github/workflows/*deploy*' 2>/dev/null || echo "")
if [ -n "$CI_DIFF" ]; then
  echo "CI_DIFF: found"
  echo "$CI_DIFF"
fi

# List all .tf files for full audit mode
echo "---"
echo "ALL_TF_FILES:"
find infra -name '*.tf' -type f | sort
echo "---"
echo "ALL_WORKFLOWS:"
find .github/workflows -name '*.yml' -o -name '*.yaml' 2>/dev/null | sort

# Terraform version
TF_VERSION=$(terraform version -json 2>/dev/null | head -1 || echo "not installed")
echo "TF_VERSION: $TF_VERSION"
```

## Input

The user may specify:
- Nothing — review `.tf` / `.tfvars` changes on the current branch against BASE
- `full` or `audit` — review the entire `infra/` tree regardless of branch diff
- A file path — review that specific file
- A PR number (e.g., `/infra-review #42`) — fetch the PR diff and review only infra files

If `TF_DIFF` is `none` and the user did not request a full audit, ask whether they want a
full audit of all infrastructure files instead.

## How This Review Works

Three phases. Phase 2 agents run in parallel.

### Phase 1: Gather Context

Read these in parallel:

1. **The diff or full tree**: If reviewing a diff, `git diff $BASE...$BRANCH -- '*.tf' '*.tfvars'`.
   If full audit, read all files under `infra/`.
2. **CLAUDE.md**: Read the project's CLAUDE.md for architecture context (especially the
   "Architecture" and "Infrastructure Targets" sections).
3. **CI/CD workflows**: Read `.github/workflows/deploy-staging.yml` and
   `.github/workflows/terraform-plan.yml` for deployment pipeline context.
4. **Terraform state backend**: Read `infra/envs/*/backend.tf` to understand state configuration.

### Phase 2: Three-Pass Review (parallel subagents)

Launch THREE agents in parallel:

**Agent A — Security & IAM Review**

Reviews against this checklist:

```
SECURITY & IAM CHECKLIST:

IAM — LEAST PRIVILEGE
- [ ] No project-level roles/editor or roles/owner grants
- [ ] Service accounts use narrowest predefined role (not roles/storage.admin when objectAdmin suffices)
- [ ] Each service account serves a single purpose (not shared across unrelated services)
- [ ] GitHub Actions SA has only the permissions it needs (run.admin, artifactregistry.writer, etc.)
- [ ] Workload Identity Federation has attribute_condition restricting repo AND branch
- [ ] No allUsers or allAuthenticatedUsers bindings except on intentionally-public Cloud Run services
- [ ] Service account keys: none committed, none generated (WIF preferred)
- [ ] Cross-SA impersonation (serviceAccountUser) is scoped to specific SA, not project-wide
- [ ] Cloud Run services use dedicated SA, not default compute SA

SECRETS
- [ ] All sensitive values use Secret Manager, not plain env_vars
- [ ] No secrets in .tf files, .tfvars committed to repo, or workflow files
- [ ] Secret accessor role granted only to SAs that need each secret
- [ ] Terraform variables for secrets are marked `sensitive = true`
- [ ] CI/CD uses GitHub Secrets for sensitive values, Variables for non-sensitive

NETWORK
- [ ] Cloud SQL: private IP preferred; public IP only with documented justification
- [ ] Cloud SQL: ssl_mode = "ENCRYPTED_ONLY" (not ALLOW_UNENCRYPTED_CONNECTIONS)
- [ ] Cloud Run: ingress restricted where possible (internal, internal-and-cloud-load-balancing)
- [ ] No overly permissive CORS (not * in production)
- [ ] ALLOWED_HOSTS is explicit, not *

HIPAA / COMPLIANCE
- [ ] No PHI in env vars, Terraform output values, or state file exposure
- [ ] Audit logging enabled (Cloud Audit Logs) for data-access operations
- [ ] GCS buckets with patient data have uniform bucket-level access
- [ ] Encryption at rest: default Google-managed or CMEK configured
- [ ] No public GCS buckets containing health data
```

**Agent B — Reliability & Cost Review**

Reviews against this checklist:

```
RELIABILITY CHECKLIST:

CLOUD SQL
- [ ] deletion_protection = true for production (false acceptable for staging with justification)
- [ ] Automated backups enabled
- [ ] Point-in-time recovery enabled
- [ ] Appropriate machine tier for workload (db-f1-micro only for dev/staging)
- [ ] Disk autoresize or sufficient disk_size_gb
- [ ] availability_type = "REGIONAL" for production (ZONAL acceptable for staging)

CLOUD RUN
- [ ] min_instances >= 1 for production (0 acceptable for staging)
- [ ] max_instances capped to prevent runaway scaling
- [ ] Memory and CPU limits set explicitly
- [ ] Health check / startup probe configured (or relying on Cloud Run defaults with understanding)
- [ ] Concurrency settings appropriate for the workload
- [ ] Revision rollback possible (not using :latest tag only in production)

CLOUD TASKS
- [ ] Retry config: max_attempts set (not unlimited)
- [ ] Rate limits configured to prevent thundering herd
- [ ] Dead letter queue or alerting for failed tasks
- [ ] OIDC token audience matches the target service URL

GCS
- [ ] Versioning enabled for important data
- [ ] Lifecycle rules for cost control (delete old versions, transition storage class)
- [ ] force_destroy = false for production buckets

STATE MANAGEMENT
- [ ] Remote backend (GCS) with state locking
- [ ] State bucket has versioning enabled
- [ ] State bucket is not publicly accessible
- [ ] Separate state per environment

COST CHECKLIST:
- [ ] Cloud SQL tier matches workload (not over-provisioned)
- [ ] Cloud Run min_instances = 0 where cold starts are acceptable (staging/dev)
- [ ] GCS lifecycle rules to clean up old objects
- [ ] No orphaned resources (unused SAs, secrets, buckets)
- [ ] Artifact Registry cleanup policy for old images
```

**Agent C — Terraform Quality & CI/CD Review**

Reviews against this checklist:

```
TERRAFORM QUALITY CHECKLIST:

MODULE DESIGN
- [ ] Modules are reusable: no hardcoded project IDs, regions, or names
- [ ] Variables have type constraints and descriptions
- [ ] Sensitive variables marked sensitive = true
- [ ] Outputs documented and useful (not exposing unnecessary internal state)
- [ ] No circular dependencies between modules
- [ ] depends_on used only when implicit dependencies are insufficient
- [ ] Resource naming follows consistent convention

CODE QUALITY
- [ ] required_version constraint on Terraform
- [ ] required_providers with version constraints (not unconstrained)
- [ ] No deprecated resource types or arguments
- [ ] for_each preferred over count for non-numeric iteration
- [ ] Dynamic blocks used appropriately (not over-engineered)
- [ ] locals used to reduce duplication
- [ ] No hardcoded values that should be variables

MIGRATION SAFETY
- [ ] Changes are backwards-compatible (no resource recreation that causes downtime)
- [ ] Renames use moved blocks, not destroy+create
- [ ] Database changes don't drop/recreate instances
- [ ] Secret renames don't destroy existing secrets with data
- [ ] terraform plan shows no unexpected destroys

CI/CD PIPELINE
- [ ] GitHub Actions: permissions are minimal (contents: read, id-token: write)
- [ ] Action versions pinned to SHA or major version (not @main or @latest)
- [ ] Concurrency controls prevent parallel deploys
- [ ] Blue-green or canary deployment (deploy with --no-traffic, then shift)
- [ ] Migration runs BEFORE traffic shift
- [ ] Secrets passed via GitHub Secrets, not hardcoded
- [ ] Terraform plan runs on PR, apply requires manual approval or merge
- [ ] Plan output posted to PR for review
```

Each agent returns findings in this format:

```
FINDING: <short title>
FILE: <path>:<line>
SEVERITY: critical | high | medium | low | nit
CATEGORY: security | iam | reliability | cost | terraform | cicd
CONFIDENCE: <1-10>
FIXABLE: yes | no
DESCRIPTION: <what's wrong and why it matters>
RISK: <what happens if this isn't fixed — data loss, cost overrun, security breach, downtime>
FIX: <exact code change if fixable, or recommendation if not>
```

### Phase 3: Merge, Deduplicate, Act

1. **Merge** findings from all three agents
2. **Deduplicate** — if multiple agents found the same issue, keep the best description
3. **Filter by confidence** — only show findings with confidence >= 6
4. **Sort** by severity (critical first), then confidence (highest first)

Then apply the **Fix-First** workflow:

#### Fix-First Rules

For each finding, decide: **auto-fix**, **ask**, or **flag**.

**Auto-fix** (do it, show what you did):
- Missing `description` on variables
- Missing `sensitive = true` on password/key/token variables
- Missing type constraints on variables
- Inconsistent naming (lowercase, hyphens for resources)
- Missing `depends_on` where implicit dependency is ambiguous
- Dead or commented-out resources

**Ask** (present the fix, wait for approval):
- IAM role changes (adding, removing, changing roles)
- Network configuration changes (public/private IP, ingress, CORS)
- Resource sizing changes (tier, memory, instances)
- Adding/removing resources
- State backend changes
- CI/CD pipeline modifications
- Any change that would trigger a `terraform plan` diff

**Flag** (report only, no fix offered):
- Architecture observations ("this module is growing complex")
- Cost optimization suggestions that require load testing to validate
- Production-readiness gaps that are acceptable in staging
- Trade-offs where either choice is valid
- Findings with confidence < 7

#### Confidence Calibration

Rate each finding 1-10:

- **9-10**: "This will cause a security breach, data loss, or outage." Evidence: you can
  trace the exact failure path. (e.g., `deletion_protection = false` on production Cloud SQL)
- **7-8**: "This violates a well-known best practice with concrete risk." (e.g., Cloud SQL
  with public IP and no authorized networks)
- **5-6**: "This could be a problem depending on context." Show it but note uncertainty.
  (e.g., max_instances = 2 might be too low for production traffic)
- **3-4**: "Possible improvement, needs context." Don't show unless asked for thorough review.
- **1-2**: "Stylistic preference." Never show.

**Display threshold**: Only show findings with confidence >= 6 by default.
If user asks for "thorough" review, lower to >= 4.

### Output Format

Present findings grouped by action:

```
## Infrastructure Review Summary

**Scope**: <N files reviewed, diff/full audit>
**Services**: <list of GCP services touched>
**Risk level**: <overall assessment: clean / low risk / medium risk / high risk>

## Auto-fixed (N items)

### 1. <title> [severity] [category] [confidence: N/10]
<file:line> — <one-line description>
<what was changed and why>

## Needs your call (N items)

### 1. <title> [severity] [category] [confidence: N/10]
<file:line> — <one-line description>
<what's wrong, risk if unfixed, proposed fix>
[Let user choose: fix / skip]

## Flagged (N items)

### 1. <title> [severity] [category] [confidence: N/10]
<file:line> — <one-line description>
<observation, risk, and recommendation>

## Production Readiness

Quick checklist of what needs to change before promoting staging → production:
- <item 1>
- <item 2>
- ...
```

If there are items in "Needs your call", use AskUserQuestion to let the user
batch-approve fixes. Group related fixes into single questions.

After user approves fixes, apply them all, then show a summary of what changed.

### If Nothing Found

If the review finds zero issues with confidence >= 6, say so clearly:
"Clean infrastructure. No issues found above the confidence threshold. N files reviewed."

Don't manufacture findings to justify the review's existence.

## Project-Specific Rules

These are specific to ht-phr / hk-labs. The skill reads CLAUDE.md for the full picture,
but these are the review-critical items:

- **Two services, one GCP project**: ht-phr and hk-labs share Cloud SQL instance, Artifact
  Registry, and GCP project. Each has its own Cloud Run service, SA, secrets, and WIF pool.
- **HIPAA-regulated**: This handles patient health records. No PHI in logs, env vars,
  Terraform state outputs, or publicly accessible storage.
- **Shared Firebase project**: `healthtree-test` — both services authenticate with the same
  Firebase project. `FIREBASE_CREDENTIALS_JSON` is a service account key passed as env var
  (flag this as a migration target — should move to Workload Identity or Secret Manager).
- **Cloud Tasks → Cloud Run**: hk-labs uses Cloud Tasks with OIDC tokens to invoke its own
  Cloud Run service. The tasks SA needs `roles/run.invoker`, and the Cloud Run SA needs
  `roles/iam.serviceAccountUser` on the tasks SA plus `roles/cloudtasks.enqueuer`.
- **Module Federation**: ht-phr frontend loads remote JS from hk-labs Cloud Run. CORS on
  hk-labs must include the ht-phr origin.
- **Blue-green deploy**: CI deploys with `--no-traffic`, runs migrations, then shifts traffic.
  Review any changes that could break this ordering.
- **State in GCS**: `ht-phr-tf-state` bucket, prefix per environment. No state locking
  beyond GCS object versioning — flag if concurrent applies are possible.
