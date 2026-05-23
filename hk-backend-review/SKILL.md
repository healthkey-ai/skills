---
name: hk-backend-review
description: "[v1.0.0] Python/Django/DRF/Celery review. Catches N+1 queries, missing indexes, unsafe migrations, task timeouts, serializer drift, and security issues."
metadata:
  version: "1.0.0"
  source: "healthkey"
---

# Backend Review

## Preamble

```bash
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
echo "BRANCH: $BRANCH"

BASE="main"
if git rev-parse --verify origin/main >/dev/null 2>&1; then
  BASE="main"
elif git rev-parse --verify origin/master >/dev/null 2>&1; then
  BASE="master"
fi
echo "BASE: $BASE"

DIFF_STAT=$(git diff "$BASE"..."$BRANCH" --stat -- '*.py' '*.sql' 2>/dev/null || echo "")
if [ -z "$DIFF_STAT" ]; then
  echo "NO_DIFF: true"
else
  echo "NO_DIFF: false"
  echo "$DIFF_STAT"
fi

FILES_CHANGED=$(git diff "$BASE"..."$BRANCH" --name-only -- '*.py' '*.sql' 2>/dev/null | wc -l | tr -d ' ')
echo "FILES_CHANGED: $FILES_CHANGED"

# Show if migrations are involved
MIGRATIONS=$(git diff "$BASE"..."$BRANCH" --name-only -- '*/migrations/*.py' 2>/dev/null)
if [ -n "$MIGRATIONS" ]; then
  echo "HAS_MIGRATIONS: true"
  echo "$MIGRATIONS"
else
  echo "HAS_MIGRATIONS: false"
fi
```

If `NO_DIFF` is `true`, tell the user there are no backend changes to review and stop.

## Input

The user may specify:
- A PR number (e.g., `/backend-review #42`) — fetch with `gh pr diff 42 -- '*.py'`
- A file or directory (e.g., `/backend-review apps/labs/`) — scope the review to that path
- Nothing — review all backend changes on the current branch against BASE

## How This Review Works

Three phases. Phase 1 gathers context, Phase 2 runs two parallel review agents, Phase 3 merges and reports.

### Phase 1: Gather Context

Read these in parallel:

1. **The diff**: `git diff $BASE...$BRANCH -- '*.py' '*.sql'` (or scoped to the user's path)
2. **CLAUDE.md**: Read the project's CLAUDE.md for conventions and architecture
3. **Recent commits**: `git log $BASE..$BRANCH --oneline` for commit intent
4. **Settings**: Read the Django settings file(s) for database, celery, middleware, and auth configuration
5. **requirements/pyproject**: Check dependency versions (Django, DRF, Celery, etc.)

### Phase 2: Two-Pass Review (parallel subagents)

Launch TWO agents in parallel:

**Agent A — Structured Best Practices Review**

Prompt the agent with the full diff and project context. It reviews against this checklist:

```
DJANGO ORM & DATABASE QUERIES
- [ ] No N+1 queries: ORM calls inside loops, list comprehensions, or serializer to_representation methods
- [ ] select_related used for ForeignKey / OneToOneField traversals in querysets
- [ ] prefetch_related used for reverse FK / M2M relationships
- [ ] No .count() on prefetched querysets — use len() to avoid extra DB hit
- [ ] No .all() followed by Python-side filtering — push filters into the queryset with .filter()
- [ ] No queries inside for/while loops — bulk fetch with __in, prefetch, or subquery instead
- [ ] Aggregations use database-native functions (Count, Sum, Avg, F, annotate) not Python loops
- [ ] Bulk operations (bulk_create, bulk_update, __in lookups) used instead of sequential .save() calls
- [ ] .exists() used instead of .count() > 0 for existence checks
- [ ] .only() / .defer() considered for wide tables when only a few columns are needed
- [ ] values() / values_list() used when full model instantiation isn't needed
- [ ] Subqueries (Subquery, OuterRef) preferred over raw SQL or multi-query approaches
- [ ] .iterator() used for very large querysets that don't need caching
- [ ] QuerySet evaluated lazily — not forcing evaluation with list() or len() prematurely
- [ ] No duplicate queries — same data fetched in view and serializer separately

DATABASE INDEXES & SCHEMA
- [ ] Every column used in WHERE, ORDER BY, JOIN, or HAVING has a db_index=True or is in index_together/indexes
- [ ] Composite indexes match the query patterns (leftmost prefix rule)
- [ ] Unique constraints on fields that should be unique (unique=True or UniqueConstraint)
- [ ] ForeignKey fields have appropriate on_delete (CASCADE, PROTECT, SET_NULL) — not defaulting blindly
- [ ] CharField has max_length set to a reasonable value — not max_length=9999
- [ ] TextField used for unbounded text, CharField for bounded
- [ ] DecimalField used for money/precision values, not FloatField
- [ ] DateTimeField uses auto_now/auto_now_add only when appropriate — not on fields the user should set
- [ ] NullBooleanField not used (deprecated) — use BooleanField(null=True)
- [ ] JSONField used with care — indexed lookups on JSON are slow without GIN indexes
- [ ] No new nullable fields on existing tables without default values (breaks existing rows)
- [ ] db_column used when Python name and DB column should differ (not renaming via migration)

MIGRATIONS
- [ ] Migration is reversible — has a reverse operation or RunPython with reverse_code
- [ ] No data loss — columns aren't dropped without data migration first
- [ ] Large table alterations are safe — no full table lock (ADD COLUMN with DEFAULT is safe in Postgres, but ALTER COLUMN TYPE is not)
- [ ] AddField with null=True done before backfill, then AlterField to non-null after
- [ ] RunPython operations are idempotent (safe to run twice)
- [ ] No import of models at module level in RunPython — use apps.get_model()
- [ ] Migration dependencies are correct (no circular, no missing)
- [ ] Indexes added in separate migration from column additions (concurrent index creation)
- [ ] No SeparateDatabaseAndState without matching SQL
- [ ] Migration file name is descriptive (not auto-generated 0042_auto_...)

DJANGO REST FRAMEWORK (DRF)
- [ ] Serializer fields match model fields — no silent data loss from typos
- [ ] read_only_fields set for fields that shouldn't be writable via API
- [ ] write_only_fields set for sensitive input (passwords, tokens)
- [ ] Nested serializers use many=True for reverse FK / M2M
- [ ] SerializerMethodField doesn't trigger extra queries — data should be annotated/prefetched in the view
- [ ] to_representation overrides don't mutate the instance — only transform the output
- [ ] validate_<field> methods used for field-level validation, validate() for cross-field
- [ ] Serializer context passed when needed (request, view, format)
- [ ] HyperlinkedModelSerializer used when API should be browsable with links
- [ ] Pagination class set on list endpoints — no unbounded querysets returned
- [ ] Filters (django-filter or manual) validated — no arbitrary field filtering that leaks data
- [ ] Ordering validated — only allowed fields, not user-supplied arbitrary ORDER BY
- [ ] Permission classes set on every view — not relying on DEFAULT_PERMISSION_CLASSES alone
- [ ] Throttling configured for expensive endpoints (uploads, LLM calls)
- [ ] API versioning considered for breaking changes
- [ ] Response status codes correct (201 for create, 204 for delete, 400 for validation errors)
- [ ] Error responses don't leak internal details (stack traces, SQL, file paths)
- [ ] Serializer validates enum/choice fields against allowed values

DJANGO VIEWS & URL PATTERNS
- [ ] ViewSet actions use appropriate HTTP methods (GET for read, POST for create, PATCH for partial update)
- [ ] Custom actions use @action decorator with correct detail= and methods=
- [ ] get_queryset() filters by authenticated user — no data leakage across users/tenants
- [ ] get_object() uses get_queryset() as base — not Model.objects.get() which bypasses permissions
- [ ] perform_create/perform_update used for side effects (setting user, sending signals)
- [ ] URL patterns don't expose sequential IDs for sensitive resources — consider UUIDs
- [ ] URL patterns use proper converters (<int:pk>, <slug:slug>) not catch-all (.*)
- [ ] No business logic in views — delegate to model methods, managers, or service functions
- [ ] Request data accessed via serializer.validated_data — not request.data directly for writes

CELERY TASKS
- [ ] Task has soft_time_limit and time_limit set (project default: 270s soft / 300s hard)
- [ ] Task handles SoftTimeLimitExceeded gracefully — saves progress, logs, returns partial result
- [ ] Task is idempotent — safe to retry or run twice without side effects
- [ ] Task arguments are serializable (no model instances, no querysets — pass IDs)
- [ ] Task uses .delay() or .apply_async() — not called synchronously in request path
- [ ] Retry logic uses exponential backoff with max_retries and retry_backoff=True
- [ ] Task status/progress tracked if long-running (update a status field, not just log)
- [ ] Task doesn't hold database connections open during external I/O (HTTP calls, LLM API)
- [ ] No task ordering assumptions — task B should not assume task A completed first
- [ ] CELERY_TASK_ALWAYS_EAGER=True in dev means async bugs only surface in production — flag code that relies on task ordering or immediate completion
- [ ] Task doesn't import at module level unnecessarily — heavy imports inside the task function
- [ ] Task result backend configured if .get() is used (or better: don't use .get() — poll status instead)
- [ ] Chord/chain/group used correctly — error handling for partial failures
- [ ] Task logging uses structlog or logger, not print()
- [ ] No sensitive data (PHI, API keys, credentials) in task arguments or return values (visible in Celery result backend)
- [ ] Task queue routing: CPU-heavy tasks on worker queue, I/O tasks on IO queue, if configured
- [ ] Database transactions: task doesn't wrap entire body in atomic() if it includes external API calls — rollback doesn't undo the API call

PYTHON CODE QUALITY
- [ ] Type hints on function signatures (parameters and return types)
- [ ] No mutable default arguments (def fn(x=[]) or def fn(x={}))
- [ ] Context managers used for resources (files, DB connections, locks)
- [ ] Exceptions are specific — not bare except: or except Exception:
- [ ] Exceptions logged with logger.exception() to preserve stack trace
- [ ] No string concatenation for SQL — use parameterized queries or ORM
- [ ] No eval(), exec(), or __import__ with user input
- [ ] os.path replaced with pathlib.Path for new code
- [ ] f-strings preferred over .format() or % formatting
- [ ] Enum or TextChoices used for fixed sets of values — not magic strings
- [ ] dataclass or NamedTuple for structured data — not bare dicts with string keys
- [ ] Generator expressions used instead of list comprehensions when only iterating once
- [ ] No circular imports — use local imports if needed
- [ ] Module-level code runs at import time — no side effects at module scope
- [ ] Tests exist for non-trivial logic (model methods, serializer validation, task logic)
- [ ] Docstrings on public module/class/function APIs (one-liner is fine)
- [ ] No commented-out code blocks

SECURITY
- [ ] No secrets, API keys, or credentials in code — use environment variables
- [ ] No raw SQL with user input — parameterized queries only
- [ ] User input validated at system boundaries (serializer, form, query params)
- [ ] File uploads validated: file type, file size, filename sanitization
- [ ] No SSRF: user-controlled URLs not passed directly to requests/httpx/urllib
- [ ] No path traversal: user input not used in file path construction
- [ ] Auth checks on every endpoint — permission_classes set or DEFAULT_PERMISSION_CLASSES adequate
- [ ] CORS / ALLOWED_HOSTS properly scoped — not * in production
- [ ] Sensitive data not logged (passwords, tokens, PHI, lab results, API keys)
- [ ] CSRF protection not disabled without reason
- [ ] Session/token expiry configured and reasonable
- [ ] Password hashing uses Django's built-in hashers — not MD5/SHA1
- [ ] Admin site protected (not exposed at /admin/ in production without IP restriction or 2FA)
- [ ] Debug mode not enabled in production (DEBUG=False)
- [ ] SECRET_KEY not hardcoded or committed
- [ ] Exported data filtered by user — no endpoints that return all users' data
- [ ] Rate limiting on auth endpoints (login, password reset, token exchange)

DJANGO SETTINGS & CONFIGURATION
- [ ] Settings split by environment (base, development, production)
- [ ] django-environ or similar used for env var parsing with defaults
- [ ] DATABASE settings use connection pooling in production (pgbouncer or CONN_MAX_AGE)
- [ ] LOGGING configured — not relying on Django defaults
- [ ] CACHES configured for production (Redis/Memcached) — not just LocMemCache
- [ ] MEDIA_ROOT and STATIC_ROOT properly configured — not serving media from app directory
- [ ] TIME_ZONE set appropriately — all datetime handling is timezone-aware
- [ ] DEFAULT_AUTO_FIELD set to BigAutoField for new projects
- [ ] INSTALLED_APPS ordered correctly (Django apps, third-party, project apps)
- [ ] Middleware order correct (SecurityMiddleware first, CorsMiddleware before CommonMiddleware)

DJANGO SIGNALS & MANAGERS
- [ ] Signals used sparingly — not as a substitute for explicit method calls
- [ ] Signal handlers are idempotent (safe to fire twice)
- [ ] Custom managers don't override default manager unless intentional
- [ ] Manager methods return querysets (composable) — complex logic in model methods
- [ ] No heavy computation in signal handlers — defer to Celery if expensive
- [ ] post_save signals don't call .save() on the same instance (infinite loop risk)

TESTING
- [ ] Tests use factories (factory_boy) or fixtures — not creating objects manually in every test
- [ ] Database tests use TransactionTestCase only when testing transactions — TestCase otherwise
- [ ] API tests use APIClient and check response status + response body
- [ ] Mock external services (LLM APIs, email, storage) — don't hit real services in tests
- [ ] Tests cover edge cases: empty input, boundary values, permission denied, not found
- [ ] No test pollution — each test is independent, no shared mutable state
- [ ] Celery tasks tested with ALWAYS_EAGER or by calling the function directly
- [ ] Migration tests exist for data migrations (RunPython)
- [ ] Performance-sensitive queries tested with assertNumQueries
```

The agent returns findings as:

```
FINDING: <short title>
FILE: <path>:<line>
SEVERITY: critical | high | medium | low | nit
CATEGORY: orm | database | migrations | drf | views | celery | python | security | settings | testing
CONFIDENCE: <1-10>
FIXABLE: yes | no
DESCRIPTION: <what's wrong and why it matters>
FIX: <exact code change if fixable, or recommendation if not>
```

**Agent B — Cross-Cutting & Production Review**

A second agent that reviews for things Agent A's checklist misses:

- **Cross-file consistency**: serializer fields match model fields match TypeScript types match API docs
- **Query pattern analysis**: trace the actual SQL a view generates — follow get_queryset → serializer → to_representation → SerializerMethodField → prefetch chain to find hidden N+1
- **Migration safety under load**: will this migration lock a table with millions of rows? Does it need to be split into steps?
- **Celery + Django interaction**: tasks that read DB state written by the request — race condition if task runs before transaction commits (use transaction.on_commit)
- **Settings that work in dev but break in prod**: CELERY_TASK_ALWAYS_EAGER masking async bugs, DEBUG=True masking error handling, SQLite vs Postgres behavior differences
- **Auth bypass paths**: combining two endpoints to access data without proper auth (e.g., unauthenticated list + authenticated detail = enumeration)
- **Data model smells**: denormalization without sync strategy, nullable fields that should have defaults, missing constraints that allow invalid state
- **API contract breaks**: field renamed/removed in serializer without frontend type update, response shape changed without versioning
- **Error propagation**: does an exception in a Celery task surface to the user? Is there a UI state for "task failed"?
- **Transaction boundaries**: atomic() wrapping code that calls external APIs (can't roll back the API call), or missing atomic() where partial writes leave inconsistent state
- **Timezone bugs**: naive datetime comparison with aware datetime, strptime without timezone, DATE_TRUNC in SQL vs Python date
- **Bulk operation edge cases**: bulk_create with ignore_conflicts silently dropping data, bulk_update with more fields than needed
- **Permission escalation**: staff-only action accessible via API because permission check is only in the admin, or object-level permission missing when queryset-level filtering is insufficient
- **Resource cleanup**: file handles, temp files, external connections not cleaned up in error paths
- **Logging quality**: are error logs actionable? Do they include enough context to debug without reproducing?

Same output format as Agent A.

### Phase 3: Merge, Deduplicate, Report

1. **Merge** findings from both agents
2. **Deduplicate** — if both found the same issue, keep the better description
3. **Filter by confidence** — only show findings with confidence >= 5
4. **Sort** by category, then severity (critical first), then confidence (highest first)

#### Fix-First Rules

For each finding, decide: **auto-fix**, **ask**, or **flag**.

**Auto-fix** (do it, show what you did):
- Missing select_related/prefetch_related on obvious N+1 patterns
- .count() on prefetched queryset → len()
- Missing db_index=True on columns used in filter/order_by
- Bare except → specific exception
- Missing type hints addable from context
- print() → logger calls
- Unused imports
- Missing read_only_fields on serializer
- Debug/print statements
- Missing aria-label equivalents in error response messages

**Ask** (present the fix, wait for approval):
- Migration changes (adding/removing fields, indexes, constraints)
- Changing queryset logic or filters
- Restructuring serializers (nesting, field changes)
- Celery task changes (retry logic, timeout, error handling)
- Permission/auth changes
- Database schema changes
- Transaction boundary changes
- API response shape changes

**Flag** (report only, no fix offered):
- Architecture observations (this view/serializer is getting too large)
- Performance concerns that need profiling or EXPLAIN ANALYZE
- Security issues that need broader discussion (auth model, data access patterns)
- Suggestions that span multiple apps
- Findings with confidence < 7

#### Confidence Calibration

- **9-10**: Definite bug or vulnerability. Traceable from code. (e.g., query inside a for loop, SQL injection, missing auth)
- **7-8**: Very likely an issue. Strong signal. (e.g., missing index on a filtered column, task without time_limit)
- **5-6**: Suspicious but context-dependent. Show it but note uncertainty. (e.g., potential race condition, possibly-slow query)
- **3-4**: Possible issue, needs investigation. Only show in thorough mode.
- **1-2**: Style preference. Never show.

**Display threshold**: Show findings with confidence >= 5 by default. If user asks for "thorough" review, lower to >= 3.

### Output Format

Present findings grouped by category:

```
## ORM & Queries ({N} findings)

### 1. <title> [severity] [confidence: N/10]
<file:line> — <one-line description>
<what's wrong, why it matters, and fix or recommendation>

## Database & Schema ({N} findings)
...

## Migrations ({N} findings)
...

## DRF Serializers & Views ({N} findings)
...

## Celery Tasks ({N} findings)
...

## Security ({N} findings)
...

## Python Code Quality ({N} findings)
...

## Settings & Configuration ({N} findings)
...

## Testing ({N} findings)
...
```

Within each category, list auto-fixed items first, then items needing approval, then flagged items.

After user approves fixes, apply them all, then show a summary of what changed.

### If Nothing Found

If the review finds zero issues with confidence >= 5, say so clearly:
"Clean diff. No backend issues found above the confidence threshold. N files reviewed."

Don't manufacture findings to justify the review.

## Project-Specific Context

These are specific to hk-labs and supplement the general checklist:

- **No PHI in logs**: This is a health app handling patient lab results. No lab values, patient identifiers, test names, or test results in log output, error messages, Celery task arguments/results, or API error responses. This is a HIPAA-class concern, not a code quality nit.
- **LLM API keys stay server-side**: `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` are used by Celery tasks for lab report extraction. They must never appear in API responses, frontend bundles, log output, or git history.
- **Auth chain**: Dual-path. Standalone uses SimpleJWT (`JWTAuthentication`). Federated uses pluggable `TokenProvider` system — `PartnerTokenView` routes tokens through `PARTNER_AUTH_PROVIDERS`. Each provider's `can_handle()` inspects unverified JWT, `verify()` validates, `_get_or_create` auto-provisions local users. Changes must preserve the `TokenProvider` base class, `PartnerTokenView` exchange flow, and `PARTNER_AUTH_PROVIDERS` config list.
- **Unit normalization pipeline**: `LabValue` stores values in the test's `default_unit`. Raw values go through `normalise()` via Pint. `source_text`/`source_unit` preserve the original. New code must not bypass this pipeline or compare raw values against normalized ones.
- **Celery task boundaries**: Extraction tasks have 270s soft / 300s hard time limit. `CELERY_TASK_ALWAYS_EAGER=True` in dev means async bugs only surface in production. Flag code that relies on task ordering or immediate completion.
- **parsed_results is a JSONField**: `UploadJob.parsed_results` is a JSON blob, not a related model. Mutations require explicit `save()`. The `to_representation` override annotates rows at read time (save_status, status, source_filename) — these are NOT persisted back.
- **Serializer ↔ TypeScript contract**: `frontend/src/types/labs.ts` mirrors `backend/apps/labs/serializers.py`. When a serializer field changes, the TS type must match. Check both directions.
- **Django settings**: Settings use django-environ with `env()`. Environment-specific settings are in `config/settings/`. `LAB_PAGINATION_DEV_SIZES` env var controls dev-only pagination sizes. Celery eager mode is detected via `any(arg.endswith("manage.py") for arg in sys.argv)`.
- **Database**: PostgreSQL in production. Indexes on all filtered/sorted columns. `select_related("test_entry", "test_entry__loinc_entry")` is the common FK chain for lab results. `values.all()` on UploadJob is prefetched — use `len()` not `.count()`.
- **Summary endpoint**: `/labs/results/summary/` aggregates values per test with a MAX_VALUES_PER_TEST cap. This is the main data source for the frontend results list. Changes here affect both standalone and federation UIs.
- **DRY**: Flag duplicated logic across files. Same pattern in two places should be extracted into a shared helper, base class, manager method, or mixin. This applies to views, serializers, tasks, and utility functions.
