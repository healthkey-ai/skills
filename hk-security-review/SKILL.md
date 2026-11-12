---
name: hk-security-review
description: "[v1.0.0] Security control review — proves auth, throttling, permissions and other controls are actually invoked and enforce their invariant, not merely present. Requires a test that fails without the fix."
metadata:
  version: "1.0.0"
  source: "shared"
---

# Security Control Review

A feature that breaks produces an error, a failed request or a user complaint.
A **control** that breaks produces success. That asymmetry is why this review
exists separately from the general code review, and why "the diff reads
correctly" is not evidence here.

Budget for roughly one real defect per review round on control code. That is not
pessimism; it is what the recorded rounds cost.

## When To Use

Run this skill when the diff touches, or should touch, a security control:

- authentication (password, token, session, SSO, impersonation)
- authorization and object-level permissions
- throttling, rate limits, lockouts, ban lists
- account deactivation, revocation, token lifetime
- CSRF, CORS, `ALLOWED_HOSTS`, proxy/IP trust, redirect allowlists
- secrets handling, encryption, key rotation
- audit logging and retention/export rules
- security gates, scanners and their baselines
- anything that decides whether a request may proceed

If a change only *consumes* a control (calls an existing helper) but the diff
does not alter the helper, the general review may be enough. If it adds a call
site, this skill applies: a control with one correct caller and one new caller
that skipped it is the failure mode this exists for.

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
# Project review profile: the project's own checklists, read in Phase 1.
# Resolve the path from the working tree, but read the base copy when the base
# has one: a diff must not be able to relax the gate it is reviewed against.
REVIEW_PROFILE=""
for p in .claude/review-profile.md docs/review-profile.md; do
  if [ -f "$p" ]; then REVIEW_PROFILE="$p"; break; fi
done
REVIEW_PROFILE_SOURCE="none"
if [ -n "$REVIEW_PROFILE" ]; then
  REVIEW_PROFILE_SOURCE="working tree"
  if [ -n "$BASE" ] && git cat-file -e "origin/${BASE}:${REVIEW_PROFILE}" 2>/dev/null; then
    REVIEW_PROFILE="origin/${BASE}:${REVIEW_PROFILE}"
    REVIEW_PROFILE_SOURCE="base"
  fi
fi
echo "REVIEW_PROFILE: ${REVIEW_PROFILE:-none}"
echo "REVIEW_PROFILE_SOURCE: $REVIEW_PROFILE_SOURCE"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "UNCOMMITTED: true"
else
  echo "UNCOMMITTED: false"
fi

DIFF_STAT=""
UNTRACKED=""
if [ -n "$MERGE_BASE" ]; then
  DIFF_STAT=$(git diff "$MERGE_BASE" --stat)
  UNTRACKED=$(git ls-files --others --exclude-standard)
fi
if [ -z "$MERGE_BASE" ]; then
  :
elif [ -z "$DIFF_STAT" ] && [ -z "$UNTRACKED" ]; then
  echo "NO_DIFF: true"
else
  echo "NO_DIFF: false"
  [ -n "$DIFF_STAT" ] && echo "$DIFF_STAT"
  [ -n "$UNTRACKED" ] && printf 'UNTRACKED:\n%s\n' "$UNTRACKED"
fi

# Files whose names suggest a control. A hint for where to start, never the
# boundary of the review: a control reaches its call sites through files that
# do not carry its name.
CONTROL_FILES=$( { [ -n "$MERGE_BASE" ] && git diff "$MERGE_BASE" --name-only; printf '%s\n' "$UNTRACKED"; } \
  | grep -Eai '(auth|permission|throttl|csrf|session|token|secur|middleware|settings|urls?|acl|role|allowlist)' || true )
if [ -n "$CONTROL_FILES" ]; then
  echo "CONTROL_FILES:"
  echo "$CONTROL_FILES"
else
  echo "CONTROL_FILES: none"
fi

FILES_CHANGED=$( { [ -n "$MERGE_BASE" ] && git diff "$MERGE_BASE" --name-only; printf '%s\n' "$UNTRACKED"; } | grep -c . )
echo "FILES_CHANGED: $FILES_CHANGED"
```

When no PR number or range was given: if `NO_DIFF` is `true`, tell the user
there are no changes to review and stop.
When no PR number or range was given: if `NO_BASE` is `true`, the base branch
could not be resolved locally: tell the user, and ask for an explicit range
(e.g. `dev..HEAD`) or a PR number instead of guessing.

## Input

With a PR number or a range, ignore `NO_DIFF` / `NO_BASE` from the preamble:
they describe the working tree, not the requested scope.
Resolve a relative path argument against `START_DIR` from the preamble, not the
repo root the preamble switched to.

The user may specify:

- A PR number (e.g., `/hk-security-review #42`) — fetch with `gh pr diff 42`
- A range (e.g., `/hk-security-review dev..HEAD`) — review `git diff dev...HEAD` (committed changes only)
- A file or directory — scope the review to that path
- Nothing — review the working tree against `MERGE_BASE`

There is **no `--fix` mode**. Control fixes are never mechanical: the fix is
only correct once a test demonstrates the failure and then the fix.

## How This Review Works

Three phases. Phase 1 builds a control inventory. Phase 2 runs two independent
passes. Phase 3 proves each claim or reports it as unproven.

### Phase 1: Build The Control Inventory

Read these in parallel:

1. **The diff**: `git diff $MERGE_BASE` plus untracked files (or the PR / range
   diff, or the user's path).
2. **Agent instructions and review profile**: `AGENTS.md` (else `CLAUDE.md`),
   and the profile the preamble reported. When its path starts with `origin/`,
   read it with `git show <ref>`: the base copy is deliberate, so the diff
   cannot relax the gate it is reviewed against. The project may name the
   control's threat model, known gaps and invariants.
3. **Control claims**: collect every statement that the change *does* something
   protective — PR description, commit messages, docstrings, comments, config
   names, test names. Write each one down. A claim with no line of code and no
   test behind it is already a finding.
4. **Call sites**: start from the preamble's `CONTROL_FILES` hint, then find
   every path that must pass through each control. A filename that does not
   carry the control's name is still a call site. Grep for the helper, decorator,
   middleware or base class; do not assume the
   diff names them. Include admin, management commands, Celery tasks, websocket
   or SSE endpoints, and a second API version if one exists.
5. **The framework's own code**: read the installed version of the framework's
   hook order (DRF `allow_request` / `get_cache_key`, Django middleware order,
   authentication backends, permission composition). Do not model it from
   memory or from the project's comments.
6. **Tests and baselines**: the tests that claim to cover the control, and any
   checked-in baseline/allowlist. A baseline is a record of known findings, not
   an exemption list to extend.

### Phase 2: Two Independent Passes

The two passes are not redundant and are not "two opinions".

**Pass A — author-context pass.** Keep the author's context: the intent, the
threat model as written, the reason the control is shaped this way. For every
claim from Phase 1, state where it is enforced — file, function, hook — and
what would have to be true for the enforcement to be skipped. Follow the code
from the entry point to the deny/allow decision.

**Pass B — fresh-context pass (a separate subagent).** Start an independent
review agent and give it **only**: the repository path, the range or diff, and
the checklist below. Do not give it this conversation, the PR description,
commit messages, the Phase 1 claim list, or any explanation of why the code is
shaped this way — those are Pass A's input. Read the control as a stranger
would: start at the route or task, find the decision, and only then read the
comment that explains it. Look for the paths the author did not mention. Check
what happens on error, on a second caller, on a deactivated account, under
concurrency, and with the feature flag off. A pass that inherits the author's
context is not the independent one.

Both passes review against this checklist:

```
INVOCATION — IS THE CONTROL REACHED AT ALL?
- [ ] The control is invoked on every path that needs it, not only the diff's path
- [ ] The framework's hook order matches the assumption (scope resolved before the key is built, middleware before the view, decorator order)
- [ ] No early return, exception, short-circuit or feature flag skips the control
- [ ] The control is registered in the place the framework actually consults (settings, decorator, base class), not only defined
- [ ] A view/route that declares no scope is not silently unthrottled
- [ ] Admin, management commands, Celery tasks and extra API versions are covered
- [ ] A second caller added in this diff goes through the same helper

IDENTITY, KEYING AND INPUT
- [ ] Absence is tested with `is None`, not truthiness — `0`, `""`, `False` are legal values
- [ ] The key the control reads is the key the framework validates (no coercion gap: serializer accepts "0" while the throttle reads 0 as absent)
- [ ] Client-supplied headers (X-Forwarded-For, X-Real-IP, Host, Origin) are trusted only as far as configured proxies
- [ ] Cache/queue/database aliases do not collide; a per-control cache namespace is not shared with broker or locks
- [ ] Normalisation happens once, at the boundary, and every consumer sees the same value

PLACEMENT AND PARITY
- [ ] The check lives in the shared primitive every caller must pass through, not in one caller
- [ ] A replacement for a framework class performs what the framework class performed (diff the subclass against the original)
- [ ] Every authentication backend and login path preserves deactivation, revocation and expiry
- [ ] Object-level permission checks use the filtered queryset, not a bare model lookup
- [ ] Defaults fail closed: a missing config value denies rather than allows

ENFORCEMENT SEMANTICS
- [ ] Deny returns the intended status (401/403/429) and does not leak which part failed
- [ ] Errors fail closed: an exception while checking does not become an allow
- [ ] Counters are atomic and consistent across workers/instances (Redis INCR, DB transaction, lock)
- [ ] TTL, window and bucket boundaries are what the comment claims
- [ ] Retries and idempotent replays cannot spend or reset another caller's allowance
- [ ] Time comparisons are timezone-aware and use a single clock source

TESTS AS EVIDENCE
- [ ] There is a test that fails when the control is removed — proven by reverting the fix, not asserted
- [ ] The test asserts the invariant, not a list of known-bad shapes
- [ ] The measurement is end-to-end through a request, not only the primitive
- [ ] The test does not mock away the control or the layer that invokes it
- [ ] Test helpers have no destructive side effects outside the test (FLUSHDB, shared queues, real broker)
- [ ] A skipped/emptied test is a finding; `pytest` exits 0 on skips

OPERABILITY AND HONESTY
- [ ] Every comment about the control describes a property a test asserts or the code visibly enforces
- [ ] Known gaps are documented next to the decision, not only in the PR
- [ ] Baselines/counts/allowlists were updated only for findings this change fixes — not regenerated to absorb a new one
- [ ] Denials are logged with enough context to investigate, and without the secret/PII
- [ ] The control has an owner-visible signal (metric, alert, log) when it stops firing

SENSITIVE DATA
- [ ] No tokens, passwords, PHI/PII or secrets in logs, error responses, task arguments/results, analytics events or client bundles
- [ ] Secrets are read from the environment/secret manager with no fallback literal
- [ ] Exported or cached data preserves the same access scoping as the live endpoint
```

Return findings in the same structured format as the other review skills:

```
FINDING: <short title>
FILE: <path>:<line>
SEVERITY: critical | high | medium | low | nit
CATEGORY: invocation | keying | placement | semantics | evidence | operability | data
CONFIDENCE: <1-10>
PROVEN: yes | no
DESCRIPTION: <the claim, the exact path that bypasses it, and why it matters>
EVIDENCE: <test/command that demonstrates the failure, or what could not be exercised>
FIX: <the shared place the check belongs, plus the test that must fail first>
```

### Phase 3: Prove Or Report As Unproven

For every control claim, fill one row:

```
| Claim | Enforced at | Evidence | Fails without the fix? | Coverage gaps stated? |
```

Rules:

1. **Run the evidence.** A test that passes with the fix is not evidence until
   it fails without it: revert, run, confirm red, restore. Do this in an
   isolated copy — a throwaway worktree at the reviewed head, or a `git stash`
   you restore and verify — and never revert committed code in the user's
   checkout. If the checkout has uncommitted work, stop and say how you will
   isolate it before touching anything. Record the command and the result. For a
   control whose test cannot be run in this environment, say so and lower
   confidence instead of upgrading it by reading.
2. **Measure end-to-end.** A failure reproduced only at the primitive may be
   unreachable through the request path. Check both before proposing a fix; a
   fix for an unreachable bug hides the reasoning that produced it.
3. **Do not accept "present" as "enforced".** Wired-but-never-invoked, defined
   but not registered, documented but not called: all are findings, not
   omissions of style.
4. **Do not fix by weakening.** Widening an allowlist, regenerating a baseline,
   disabling a scanner rule, or turning a control off to make tests pass are
   findings in their own right.
5. **Never auto-fix.** Present each control fix with the test that must fail
   first, and wait for approval. If the fix changes a default, a flag or an
   auth/permission decision, it needs the owner's call.

### Confidence Calibration

- **9-10**: the failure path is traced end-to-end *and* executed, or a test
  was reverted to prove the control is load-bearing.
- **7-8**: the bypass is traced through the framework's own code, but not
  executed (e.g. a subclass omits a check the framework performs).
- **5-6**: the control reads as unreachable or incomplete, and the assumption
  could not be verified. Show it as unproven, not as a finding of absence.
- **3-4**: possible issue, needs investigation. Only in a thorough review.
- **1-2**: style. Never show.

**Display threshold**: findings with confidence >= 5. Anything about a control
that was never executed cannot exceed 6.

### Output Format

```
## Control claims ({N})
| Claim | Enforced at | Evidence | Fails without fix? | Gaps stated? |

## Confirmed defects ({N})
### 1. <title> [critical] [confidence: 10/10] [proven]
<file:line> — <the bypass, in one sentence>
<what the control promises, where it is skipped, and the test/command that shows it>

## Unproven claims ({N})
### 1. <title> [severity] [confidence: N/10] [not exercised]
<file:line> — <the assumption and what could not be measured>
<what evidence would settle it>

## Gaps and follow-ups ({N})
...
```

If there are confirmed defects, offer each fix with its failing test and wait
for approval. After applying, show the red-then-green result for each.

### If Nothing Found

Say exactly what was executed. "No findings" without an executed test, a
reverted control, or an exercised request path is not a clean review — report
those claims as unproven instead.

## Project Conventions

The project's agent instructions and review profile are authoritative; the
patterns below are the generic part that recurs across projects. When a project
ships a review profile (`.claude/review-profile.md` or
`docs/review-profile.md`), apply its domain gates on top of these defaults.

- **Recorded failure modes beat a generic checklist.** Projects that have
  already been burned by a control defect should keep the cases in the profile
  (wired-never-invoked, truthiness for absence, check in the caller, a subclass
  that omitted the framework's check, destructive test helpers). Review against
  theirs first.
- **A control is not a feature.** No error is raised when it stops working, so
  tests are the only detector. Treat "there is a test" as a claim to verify.
- **Two passes, one with context and one without.** The value is the
  deliberately uninformed pass, not a second agreeing opinion.
- **Comments are part of the control surface.** A comment describing a call
  that does not exist, or a threat model that was replaced, is a finding.
- **State the negative space.** If the control does not cover signup, a second
  provider, or an already-issued token, that belongs next to the decision in
  code. A control described as more complete than it is will be relied on.
- **Baselines are counts, not lists of exemptions.** A baseline that can absorb
  a new finding unchanged is not a control. Check which one this project uses.
