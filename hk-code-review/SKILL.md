---
name: hk-code-review
description: "[v1.0.0] Review branch diff against base. Finds bugs, security, and design issues. Auto-fixes mechanical problems, asks before design changes."
metadata:
  version: "1.0.0"
  source: "healthkey"
---

# Code Review

## Preamble

```bash
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
echo "BRANCH: $BRANCH"

# Detect base branch
BASE="main"
if git rev-parse --verify origin/main >/dev/null 2>&1; then
  BASE="main"
elif git rev-parse --verify origin/master >/dev/null 2>&1; then
  BASE="master"
fi
echo "BASE: $BASE"

# Check we have something to review
DIFF_STAT=$(git diff "$BASE"..."$BRANCH" --stat 2>/dev/null || git diff "$BASE"..HEAD --stat 2>/dev/null || echo "")
if [ -z "$DIFF_STAT" ]; then
  echo "NO_DIFF: true"
else
  echo "NO_DIFF: false"
  echo "$DIFF_STAT"
fi

# Count files changed
FILES_CHANGED=$(git diff "$BASE"..."$BRANCH" --name-only 2>/dev/null | wc -l | tr -d ' ')
echo "FILES_CHANGED: $FILES_CHANGED"
```

If `NO_DIFF` is `true`, tell the user there are no changes to review and stop.

## Input

The user may specify:
- A PR number (e.g., `/review #42`) — fetch with `gh pr diff 42`
- A branch comparison (e.g., `/review dev..main`) — use that range
- Nothing — review current branch against BASE detected in preamble

If the user mentions "today's PRs" or similar, list recent merged PRs with
`gh pr list --state merged --limit 10` and review those diffs.

## How This Review Works

Three phases. Phase 1 and the two Phase 2 agents run in parallel where possible.

### Phase 1: Gather Context

Read these in parallel (use Agent tool for the diff if it's large):

1. **The diff**: `git diff $BASE...$BRANCH` (or PR diff)
2. **CLAUDE.md**: Read the project's CLAUDE.md for conventions and architecture
3. **Recent commits**: `git log $BASE..$BRANCH --oneline` for commit intent

### Phase 2: Two-Pass Review (parallel subagents)

Launch TWO agents in parallel:

**Agent A — Structured Review**

Prompt the agent with the full diff and CLAUDE.md context. It reviews against
this checklist (DO NOT depend on any external checklist file):

```
REVIEW CHECKLIST (check every item against the diff):

SECURITY
- [ ] No secrets, API keys, tokens, or credentials in code or config committed to repo
- [ ] User input validated/sanitized at system boundaries
- [ ] No SQL injection (raw queries with string interpolation)
- [ ] No XSS (unescaped user content in templates/JSX)
- [ ] No SSRF (user-controlled URLs passed to fetch/urlopen/requests)
- [ ] No path traversal (user input in file paths)
- [ ] Auth checks on every endpoint that needs them
- [ ] CORS/ALLOWED_HOSTS properly scoped (not * in production)
- [ ] Sensitive data not logged (passwords, tokens, PHI, lab results)
- [ ] HIPAA: no PHI or lab values in logs, env vars, or client-visible error responses
- [ ] LLM API keys (ANTHROPIC_API_KEY, OPENAI_API_KEY) never exposed to frontend

CORRECTNESS
- [ ] Error handling exists where operations can fail (network, DB, file I/O, Celery tasks)
- [ ] No silent exception swallowing (bare except/catch without logging)
- [ ] Race conditions in concurrent code (async, threads, DB transactions, Celery workers)
- [ ] Null/undefined handled for optional data
- [ ] Edge cases: empty collections, zero values, boundary conditions
- [ ] Database migrations are safe (no data loss, reversible)
- [ ] API contracts match between frontend types (src/types/labs.ts) and backend serializers
- [ ] Unit conversion logic preserves precision (Pint/normalise round-trips)
- [ ] parsed_results JSONField mutations are saved (UploadJob.save after mutating)

ARCHITECTURE — FRONTEND AS PRESENTATION LAYER
- [ ] No client-side sorting/grouping of unpaginated backend payloads
- [ ] No complex data aggregation (.reduce(), multi-condition .filter()) in components — backend should provide pre-computed shapes
- [ ] Frontend receives fully prepared JSON optimized for immediate rendering
- [ ] Flag any .filter or .reduce handling more than two conditions on an API payload
- [ ] Sorting, multi-attribute filtering, pagination, and statistical aggregations happen on the backend

ARCHITECTURE — BACKEND QUERY OPTIMIZATION
- [ ] No N+1 queries (ORM calls in loops — check serializer to_representation methods)
- [ ] No unbounded queries (missing LIMIT/pagination on tables that grow continuously)
- [ ] Every column used in WHERE, ORDER BY, JOIN, or foreign key has an explicit database index
- [ ] Eager loading: related models prefetched/joined in a single query (select_related/prefetch_related)
- [ ] Aggregations use database-native functions (Count, Sum, Avg, annotate) not application-level loops
- [ ] No queries inside loops — bulk fetch with __in or prefetch instead
- [ ] Flag any backend query executed inside a for/while loop

PERFORMANCE
- [ ] No blocking I/O in async paths or Celery tasks without timeout
- [ ] Large data processed in batches, not loaded entirely into memory

CODE QUALITY — DRY
- [ ] No duplicated logic across files — extract shared helpers or base classes
- [ ] No copy-pasted code blocks with minor variations — parameterize instead
- [ ] Flag any code block appearing substantially identical in two or more places

INFRASTRUCTURE
- [ ] Docker/CI changes don't break the build pipeline
- [ ] Environment variables documented or have sensible defaults
- [ ] Celery task changes respect soft/hard time limits (270s/300s)
- [ ] Django settings changes work in both development and production
- [ ] Module Federation config (vite.remote.config.ts) stays compatible with host app

DESIGN
- [ ] New code follows existing patterns in the codebase
- [ ] No premature abstractions or over-engineering
- [ ] Public API surface is minimal and well-named
- [ ] No dead code or commented-out blocks
- [ ] Test coverage for non-trivial logic
- [ ] Frontend state derived from backend (no client-side guessing of save_status, duplicates, etc.)
```

The agent should return findings as a structured list:

```
FINDING: <short title>
FILE: <path>:<line>
SEVERITY: critical | high | medium | low | nit
CATEGORY: security | correctness | performance | infrastructure | design
CONFIDENCE: <1-10>
FIXABLE: yes | no
DESCRIPTION: <what's wrong and why it matters>
FIX: <exact code change if fixable, or recommendation if not>
```

**Agent B — Adversarial Review**

A second agent that ONLY looks for things Agent A would miss:

- Interactions between changed files (e.g., frontend types expect a field the serializer doesn't send)
- Subtle state management bugs (React Query cache coherence, stale closures, refetchInterval timing)
- Things that work in dev but break in production (localhost assumptions, missing env vars, CELERY_TASK_ALWAYS_EAGER masking async bugs)
- Security issues that span multiple files (e.g., auth bypass by combining two endpoints)
- Missing error paths that would leave users stuck (Celery task failures not surfacing in the UI)
- Unit conversion edge cases (molecular_weight=None, unknown units, zero values)
- Module Federation boundary issues (shared dependencies, hook context availability in remote)
- Frontend doing backend work: client-side sorting, filtering, aggregation, or deduplication that should be a query param or backend endpoint
- Backend query patterns: N+1 hiding in serializer methods, missing indexes on new filter/sort columns, unbounded querysets without pagination
- Code duplication: same logic repeated across files or components with minor variations instead of shared helpers

Same output format as Agent A.

### Phase 3: Merge, Deduplicate, Act

1. **Merge** findings from both agents
2. **Deduplicate** — if both agents found the same issue, keep the better description
3. **Filter by confidence** — only show findings with confidence >= 6
4. **Sort** by severity (critical first), then confidence (highest first)

Then apply the **Fix-First** workflow:

#### Fix-First Rules

For each finding, decide: **auto-fix**, **ask**, or **flag**.

**Auto-fix** (do it, show what you did):
- Missing error handling / silent exception swallowing
- Missing timeout on network calls
- Secrets or credentials accidentally committed
- `ALLOWED_HOSTS = "*"` or `CORS = "*"` in production config
- Dead code, debug statements (console.log, print, debugger)
- Obvious typos in code (not comments)
- Missing `select_related`/`prefetch_related` on obvious N+1 patterns
- Copy-pasted code blocks that can be trivially extracted into a shared helper

**Ask** (present the fix, wait for approval):
- Design changes (restructuring, new abstractions, API changes)
- Removing or changing existing functionality
- Performance optimizations that change behavior
- Anything touching auth/permissions logic
- Database migration changes
- Celery task changes (timeouts, retry logic, error handling)
- Serializer contract changes (fields added/removed/renamed)
- Module Federation config or shared dependency changes

**Flag** (report only, no fix offered):
- Informational observations (e.g., "this serializer is getting large")
- Suggestions that require broader context the reviewer doesn't have
- Trade-offs where either choice is valid
- Findings with confidence < 7

#### Confidence Calibration

Rate each finding 1-10:

- **9-10**: "I would bet money this is a bug/vulnerability." Evidence: you can trace the exact failure path. (e.g., `urlopen()` with no timeout will hang the Celery worker)
- **7-8**: "This is very likely a problem." Strong signal but you haven't verified every assumption. (e.g., missing index on a column used in WHERE clause)
- **5-6**: "This looks suspicious but I could be wrong." Show it but note uncertainty. (e.g., potential race condition in concurrent upload commits)
- **3-4**: "Possible issue, needs investigation." Don't show unless asked for thorough review.
- **1-2**: "Wild guess." Never show.

**Display threshold**: Only show findings with confidence >= 6 by default.
If user asks for "thorough" review, lower to >= 4.

### Output Format

Present findings grouped by action:

```
## Auto-fixed (N items)

### 1. <title> [severity] [confidence: N/10]
<file:line> — <one-line description>
<what was changed and why>

## Needs your call (N items)

### 1. <title> [severity] [confidence: N/10]
<file:line> — <one-line description>
<what's wrong, why it matters, proposed fix>
[Let user choose: fix / skip]

## Flagged (N items)

### 1. <title> [severity] [confidence: N/10]
<file:line> — <one-line description>
<observation and recommendation>
```

If there are items in "Needs your call", use AskUserQuestion to let the user
batch-approve fixes. Group related fixes into single questions where it makes sense.

After user approves fixes, apply them all, then show a summary of what changed.

### If Nothing Found

If the review finds zero issues with confidence >= 6, say so clearly:
"Clean diff. No issues found above the confidence threshold. N files reviewed, M lines changed."

Don't manufacture findings to justify the review's existence.

## Project-Specific Rules

These are specific to hk-labs. The skill reads CLAUDE.md for the full picture, but
these are the review-critical items that come up repeatedly:

- **No PHI or lab values in logs** — this is a health app handling patient lab results. No lab values, patient identifiers, or test results in log output or error messages exposed to the client.
- **LLM API keys stay server-side** — `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` are used by Celery tasks for lab report extraction. They must never appear in frontend bundles, API responses, or git history.
- **Auth chain**: Dual-path. Standalone mode uses SimpleJWT (`JWTAuthentication`). Federated mode uses the pluggable `TokenProvider` system — host apps send their bearer token (Firebase, Auth0, Cognito, etc.) to `PartnerTokenView`, which routes it through `PARTNER_AUTH_PROVIDERS`. Each provider's `can_handle()` inspects the unverified JWT payload to claim ownership, then `verify()` validates it, and `PartnerAuthentication._get_or_create` auto-provisions local users. The exchange returns local SimpleJWT pairs. Firebase is one configured provider (`FirebaseTokenProvider`), not the only possible one. Changes to auth must preserve the provider abstraction (`TokenProvider` base class), the `PartnerTokenView` exchange flow, and the `PARTNER_AUTH_PROVIDERS` config list.
- **Frontend is a presentation layer** — save_status, duplicate detection, unit normalization, status computation, sorting, filtering, aggregation, and pagination all happen on the backend. The frontend must never re-derive or re-compute these. If you see the frontend doing `.filter()` with more than two conditions on an API payload, `.reduce()` for aggregation, client-side sorting of backend data, or client-side deduplication, flag it. The frontend should receive fully prepared JSON shapes optimized for immediate rendering.
- **Unit normalization pipeline** — `LabValue` stores values in the test's `default_unit`. Raw values go through `normalise()` (via Pint). The `source_text`/`source_unit` fields preserve the original. Reviews must check that new code doesn't bypass this pipeline or compare raw values against normalized ones.
- **Celery task boundaries** — Extraction tasks have a 270s soft / 300s hard time limit. New task code must respect this. `CELERY_TASK_ALWAYS_EAGER=True` in dev means async bugs only surface in production — flag any code that relies on task ordering or immediate completion.
- **Module Federation** — The frontend ships both as a standalone Vite app (`vite.config.ts`) and as a Module Federation remote (`vite.remote.config.ts`). Changes to shared dependencies, context providers, or route structure must work in both modes.
- **Serializer ↔ TypeScript contract** — `frontend/src/types/labs.ts` mirrors `backend/apps/labs/serializers.py`. When a serializer field changes, the TS type must match. Check both directions.
- **parsed_results is a JSONField** — `UploadJob.parsed_results` is a JSON blob, not a related model. Mutations to it require an explicit `save()`. The `to_representation` override annotates rows at read time (save_status, status, source_filename) — these annotations are NOT persisted back.
- **Database query optimization** — Every new queryset must be checked for: N+1 (queries inside loops or serializer methods), missing indexes on columns used in WHERE/ORDER BY/JOIN, unbounded queries on growing tables (must have pagination or LIMIT), and aggregations done in Python loops instead of database-native functions (Count, Sum, annotate). Use `select_related`/`prefetch_related` aggressively. Bulk operations (`__in`, `bulk_update`, `bulk_create`) over sequential saves.
- **DRY** — Flag duplicated logic across files. Same pattern in two places should be extracted into a shared helper, base class, or utility. This applies to both frontend (shared hooks, components, utils) and backend (shared mixins, managers, helpers).
