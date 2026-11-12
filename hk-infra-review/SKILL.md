---
name: hk-infra-review
description: "[v1.3.0] Review GCP infrastructure and Terraform code for security, cost, reliability, and CI/CD best practices."
metadata:
  version: "1.3.0"
  source: "shared"
---

# Infra Review

## Preamble

```bash
# Paths below are relative to the repo root, wherever the review was started.
START_DIR=$(pwd)
echo "START_DIR: $START_DIR"
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# Network calls below must fail fast rather than wait for an HTTPS credential prompt.
export GIT_TERMINAL_PROMPT=0

BRANCH=$(git branch --show-current 2>/dev/null)
echo "BRANCH: ${BRANCH:-detached}"

# Default branch from origin itself: a clone's cached origin/HEAD is not
# updated by fetch and goes stale when the default branch is changed. (Not
# `gh repo view`: it may resolve to another remote than origin.)
DEFAULT=$(git ls-remote --symref origin HEAD 2>/dev/null | sed -n 's#^ref: refs/heads/\(.*\)[[:space:]]HEAD$#\1#p')
if [ -z "$DEFAULT" ]; then
  DEFAULT=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
fi
if [ -z "$DEFAULT" ]; then
  for b in main master; do
    if git rev-parse --verify -q "origin/$b" >/dev/null; then DEFAULT="$b"; break; fi
  done
fi

# Base: the open PR's base if this feature branch has one, else the default branch.
BASE=""
if [ -n "$BRANCH" ] && [ "$BRANCH" != "$DEFAULT" ]; then
  BASE=$(gh pr view --json baseRefName,state -q 'select(.state == "OPEN") | .baseRefName' 2>/dev/null || true)
fi
BASE=${BASE:-$DEFAULT}
echo "BASE: ${BASE:-unknown}"

# Diff from the merge-base to the working tree, so uncommitted edits are reviewed too.
# The explicit refspec also works in single-branch clones.
if [ -n "$BASE" ] && ! git rev-parse --verify -q "origin/$BASE" >/dev/null; then
  # Braces matter: zsh would read "$BASE:r" as the :r (strip extension) modifier.
  git fetch -q origin "+refs/heads/${BASE}:refs/remotes/origin/${BASE}" 2>/dev/null || true
fi
MERGE_BASE=$(git merge-base "origin/$BASE" HEAD 2>/dev/null || true)
if [ -z "$MERGE_BASE" ]; then
  echo "NO_BASE: true"
else
  echo "MERGE_BASE: $MERGE_BASE"
fi
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "UNCOMMITTED: true"
else
  echo "UNCOMMITTED: false"
fi

# Check for .tf changes
TF_DIFF=""
TF_DIFF_STAT=""
if [ -n "$MERGE_BASE" ]; then
  TF_DIFF=$( { git diff "$MERGE_BASE" --name-only -- '*.tf' '*.tfvars'; git ls-files --others --exclude-standard -- '*.tf' '*.tfvars'; } | grep . )
  TF_DIFF_STAT=$(git diff "$MERGE_BASE" --stat -- '*.tf' '*.tfvars')
fi

if [ -z "$TF_DIFF" ]; then
  echo "TF_DIFF: none"
else
  echo "TF_DIFF: found"
  echo "$TF_DIFF"
  echo "---"
  echo "$TF_DIFF_STAT"
fi

UNTRACKED=$(git ls-files --others --exclude-standard -- '*.tf' '*.tfvars' '.github/workflows/*terraform*' '.github/workflows/*deploy*')
[ -n "$UNTRACKED" ] && printf 'UNTRACKED:\n%s\n' "$UNTRACKED"

# Also check for workflow changes that touch infra
CI_DIFF=""
if [ -n "$MERGE_BASE" ]; then
  CI_DIFF=$( { git diff "$MERGE_BASE" --name-only -- '.github/workflows/*terraform*' '.github/workflows/*deploy*'; git ls-files --others --exclude-standard -- '.github/workflows/*terraform*' '.github/workflows/*deploy*'; } | grep . )
fi
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
- Nothing — review `.tf` / `.tfvars` changes in the working tree (committed + uncommitted + untracked) against MERGE_BASE
- A range (e.g., `/hk-infra-review dev..HEAD`) — review `git diff dev...HEAD -- '*.tf' '*.tfvars'` (committed changes only)
- `full` or `audit` — review the entire `infra/` tree regardless of branch diff
- A file path — review that specific file
- A PR number (e.g., `/hk-infra-review #42`) — fetch with `gh pr diff 42` and review only the infra files in it
- `--fix` — apply mechanical fixes without asking (see Fix Mode)

With a PR number, a range, a file path or `full`/`audit`, ignore `TF_DIFF` / `NO_BASE` from the
preamble: they describe the working tree, not the requested scope.
Resolve a relative path argument against `START_DIR` from the preamble, not the
repo root the preamble switched to.

When no scope was given: if `TF_DIFF` is `none`, ask whether they want a
full audit of all infrastructure files instead.

When no scope was given: if `NO_BASE` is `true`, the base branch could not be resolved locally: tell the user, and ask for an explicit range (e.g. `dev..HEAD`) or a PR number or a full audit, instead of guessing.

## How This Review Works

Three phases. Phase 2 agents run in parallel.

### Phase 1: Gather Context

Read these in parallel:

1. **The diff or full tree**: If reviewing a diff, `git diff $MERGE_BASE -- '*.tf' '*.tfvars'` plus the untracked `.tf` / `.tfvars` files listed in `TF_DIFF` (and untracked workflows in `CI_DIFF`).
   If full audit, read all files under `infra/`.
2. **Agent instructions**: Read the project's `AGENTS.md` (or its `CLAUDE.md` when there is no `AGENTS.md`) for architecture context (especially the "Architecture" and "Infrastructure Targets" sections).
3. **Review profile**: Read `.claude/review-profile.md` or `docs/review-profile.md` if the preamble found one. It is the project's own addendum — domain checklists, commands and gates — and where it is more specific than this skill, it wins.
4. **CI/CD workflows**: Read `.github/workflows/deploy-staging.yml` and
   `.github/workflows/terraform-plan.yml` for deployment pipeline context.
5. **Terraform state backend**: Read `infra/envs/*/backend.tf` to understand state configuration.

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

DATA PROTECTION / COMPLIANCE
- [ ] No sensitive or regulated data (PII, secrets) in env vars, Terraform output values, or state file exposure
- [ ] Audit logging enabled (Cloud Audit Logs) for data-access operations
- [ ] GCS buckets with sensitive data have uniform bucket-level access
- [ ] Encryption at rest: default Google-managed or CMEK configured
- [ ] No public GCS buckets containing sensitive or regulated data
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

#### Fix Mode

By default this review **does not edit files**. Findings in the auto-fix class
below are presented as "Ready to fix" and applied only after the user approves
them: whenever there is a ready-to-fix or ask finding, use AskUserQuestion to
batch-approve them.

Only when the user passed `--fix` are auto-fix findings applied immediately, as
"Auto-fixed". Even then, if the preamble printed `UNCOMMITTED: true` or a
non-empty `UNTRACKED` list, say so before editing: the fixes will be mixed into
the user's uncommitted work. With a PR number or a range, apply fixes only if
the checked-out branch is that PR's head (or the range's head); otherwise
report them without editing.

#### Fix-First Rules

For each finding, decide: **auto-fix**, **ask**, or **flag**.

**Auto-fix** (mechanical; applied after approval, or immediately with `--fix`):
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

## Ready to fix (N items)  <!-- "Auto-fixed" with --fix -->

### 1. <title> [severity] [category] [confidence: N/10]
<file:line> — <one-line description>
<proposed change and why (with --fix: what was changed)>

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

If there are items in "Ready to fix" or "Needs your call", use AskUserQuestion to let the user
batch-approve fixes. Group related fixes into single questions.

After user approves fixes, apply them all, then show a summary of what changed.

### If Nothing Found

If the review finds zero issues with confidence >= 6, say so clearly:
"Clean infrastructure. No issues found above the confidence threshold. N files reviewed."

Don't manufacture findings to justify the review's existence.

## Project Conventions

The skill reads the project's agent instructions and review profile for the
full picture. When a project ships a review profile (`.claude/review-profile.md`
or `docs/review-profile.md`), treat it as the authoritative project addendum:
apply its domain checklists, commands and gates on top of the defaults below,
and let it override them where the two disagree. Without one, the defaults
apply unchanged. These review-critical
patterns recur across GCP/Terraform projects on this stack:

- **Multiple services, one GCP project**: when several services share a Cloud SQL instance,
  Artifact Registry, and GCP project, each should still have its own Cloud Run service, SA,
  secrets, and WIF pool. Flag shared SAs or secrets that cross service boundaries.
- **Regulated data**: if the project handles regulated or sensitive data, keep it out of logs,
  env vars, Terraform state outputs, and publicly accessible storage.
- **Shared identity provider**: when services share a Firebase/auth project, a credentials JSON
  passed as an env var is a migration target — flag it and recommend Workload Identity or
  Secret Manager.
- **Cloud Tasks → Cloud Run**: a service using Cloud Tasks with OIDC tokens to invoke its own
  Cloud Run service needs the tasks SA to have `roles/run.invoker`, and the Cloud Run SA to
  have `roles/iam.serviceAccountUser` on the tasks SA plus `roles/cloudtasks.enqueuer`.
- **Module Federation**: when one frontend loads remote JS from another service's Cloud Run,
  the remote's CORS must include the host origin.
- **Blue-green deploy**: a common pattern deploys with `--no-traffic`, runs migrations, then
  shifts traffic. Review any change that could break this ordering.
- **State in GCS**: a per-environment prefix in a GCS state bucket with no locking beyond object
  versioning is risky — flag if concurrent applies are possible.
