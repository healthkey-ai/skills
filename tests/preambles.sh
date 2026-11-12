#!/usr/bin/env bash
# Runs the ```bash preamble of every SKILL.md under bash and zsh (the agent's
# shell may be either) against throwaway git repos, and checks the base the
# preamble resolves. Branch names with dots and slashes are deliberate: zsh
# reads "$VAR:r" / "$VAR:h" as modifiers, which bash does not.
#
#   tests/preambles.sh            # needs git, bash, zsh; gh is stubbed
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0
checks=0

# gh stub: `pr view` prints $GH_PR_BASE (an open PR's base) or fails;
# everything else fails, as when gh is missing or unauthenticated.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/bin/sh
if [ "$1 $2" = "pr view" ] && [ -n "${GH_PR_BASE:-}" ]; then echo "$GH_PR_BASE"; exit 0; fi
exit 1
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

for skill in "$REPO_ROOT"/*/SKILL.md; do
  name=$(basename "$(dirname "$skill")")
  awk '/^```bash$/{f=1;next} /^```$/{if(f){exit}} f' "$skill" > "$WORK/$name.sh"
done

# Remote "o.git": main, dev (default), release/1.2 and 2omop, each one commit ahead.
git init -q --bare -b main "$WORK/o.git"
git clone -q "$WORK/o.git" "$WORK/seed" 2>/dev/null
( cd "$WORK/seed" && git commit -q --allow-empty -m root && git push -q origin HEAD:main
  for b in dev release/1.2 2omop; do
    git checkout -q -b "$b" main && git commit -q --allow-empty -m "$b" && git push -q origin "$b"
  done )
git -C "$WORK/o.git" symbolic-ref HEAD refs/heads/main

# clone: made while the default was main, so its cached origin/HEAD is stale.
git clone -q "$WORK/o.git" "$WORK/clone" 2>/dev/null
git -C "$WORK/o.git" symbolic-ref HEAD refs/heads/dev
git -C "$WORK/clone" fetch -q
# single: a single-branch clone that has never seen any base but main.
git clone -q --single-branch -b main "$WORK/o.git" "$WORK/single" 2>/dev/null
# dirty: a feature branch with committed, modified and untracked files.
git clone -q "$WORK/o.git" "$WORK/dirty" 2>/dev/null
( cd "$WORK/dirty" && git checkout -q -b feat origin/dev && mkdir -p app infra &&
  echo a > app/models.py && echo b > app/ui.tsx && git add app && git commit -q -m feat &&
  echo changed >> app/models.py &&
  mkdir -p app/migrations && echo m > app/migrations/0002_x.py && echo 'x = 1' > infra/prod.tfvars )
# noremote: no origin at all.
git init -q -b main "$WORK/noremote" && git -C "$WORK/noremote" commit -q --allow-empty -m x

expect() { # <label> <output> <regex>
  checks=$((checks + 1))
  if ! printf '%s\n' "$2" | grep -Eq "$3"; then
    echo "FAIL  $1: expected /$3/"; printf '%s\n' "$2" | sed 's/^/      | /'
    fails=$((fails + 1))
  fi
}

# Each case: <repo> <branch to create> <start point> <GH_PR_BASE> <expected BASE> <expect merge-base?>
# Every shell x skill run gets its own copy, so one run's fetch cannot help the next.
run_case() {
  local repo=$1 branch=$2 from=$3 pr=$4 want=$5 mb=$6
  local script s out label dir want_mb out_bash
  for script in "$WORK"/*.sh; do
    s=$(basename "$script" .sh)
    out_bash=""
    for sh in bash zsh; do
      dir="$WORK/case-$RANDOM$RANDOM"
      cp -R "$WORK/$repo" "$dir"
      git -C "$dir" checkout -q -B "$branch" "$from"
      mkdir -p "$dir/sub"
      out=$(cd "$dir/sub" && GH_PR_BASE="$pr" "$sh" "$script" 2>&1 | grep -v '^START_DIR: ')
      label="$s [$sh] repo=$repo branch=$branch pr=${pr:-none}"
      expect "$label" "$out" "^BASE: ${want//./\\.}\$"
      if [ "$mb" = yes ]; then
        want_mb=$(git -C "$dir" merge-base "origin/$want" HEAD)
        expect "$label" "$out" "^MERGE_BASE: $want_mb\$"
      else
        expect "$label" "$out" "^NO_BASE: true\$"
      fi
      if [ "$sh" = bash ]; then
        out_bash=$out
      else
        checks=$((checks + 1))
        if [ "$out" != "$out_bash" ]; then
          echo "FAIL  $s repo=$repo branch=$branch: bash and zsh output differ"
          diff <(printf '%s\n' "$out_bash") <(printf '%s\n' "$out") | sed 's/^/      | /'
          fails=$((fails + 1))
        fi
      fi
      rm -rf "$dir"
    done
  done
}

run_case clone    feat main       ""          dev          yes  # stale origin/HEAD: still dev
run_case clone    feat main       release/1.2 release/1.2  yes  # PR base with . and /
run_case single   feat main       2omop       2omop        yes  # base never fetched
run_case single   feat main       release/1.2 release/1.2  yes
run_case clone    dev  origin/dev main        dev          yes  # on the default branch: PR ignored
run_case noremote feat main       ""          unknown      no

# The dirty tree, run from a subdirectory: paths are root-relative and
# uncommitted / untracked work is counted.
dirty_check() { # <skill> <regex>...
  local s=$1 out; shift
  out=$(cd "$WORK/dirty/app" && GH_PR_BASE="" bash "$WORK/$s.sh" 2>&1)
  for re in "$@"; do expect "$s [dirty]" "$out" "$re"; done
}
dirty_check hk-code-review     '^NO_DIFF: false$' '^UNCOMMITTED: true$' '^app/migrations/0002_x\.py$' '^infra/prod\.tfvars$' '^FILES_CHANGED: 4$' '^REVIEW_PROFILE: none$' '^REVIEW_PROFILE_SOURCE: none$'
dirty_check hk-backend-review  '^FILES_CHANGED: 2$' '^HAS_MIGRATIONS: true$' '^app/migrations/0002_x\.py$' '^REVIEW_PROFILE: none$' '^REVIEW_PROFILE_SOURCE: none$'
dirty_check hk-frontend-review '^FILES_CHANGED: 1$' '^REVIEW_PROFILE: none$' '^REVIEW_PROFILE_SOURCE: none$'
dirty_check hk-infra-review    '^TF_DIFF: found$' '^infra/prod\.tfvars$' '^REVIEW_PROFILE: none$' '^REVIEW_PROFILE_SOURCE: none$'
dirty_check hk-security-review '^FILES_CHANGED: 4$' '^CONTROL_FILES: none$' '^REVIEW_PROFILE: none$' '^REVIEW_PROFILE_SOURCE: none$'

# A control-shaped filename is reported even though it is only a hint.
echo 'x = 1' > "$WORK/dirty/app/auth.py"
out=$(cd "$WORK/dirty/app" && GH_PR_BASE="" bash "$WORK/hk-security-review.sh" 2>&1)
expect "hk-security-review [control]" "$out" '^CONTROL_FILES:$'
expect "hk-security-review [control]" "$out" '^app/auth\.py$'

# The profile block is self-contained per skill; keep the five copies identical.
profile_block() {
  awk '/^# Project review profile:/{f=1} f{print} f&&/^echo "REVIEW_PROFILE_SOURCE:/{exit}' "$1"
}
first=""; first_file=""
for f in "$REPO_ROOT"/*/SKILL.md; do
  block=$(profile_block "$f")
  checks=$((checks + 1))
  if [ -z "$block" ]; then
    echo "FAIL  profile block missing: $f"
    fails=$((fails + 1))
    continue
  fi
  if [ -z "$first_file" ]; then first=$block; first_file=$f; continue; fi
  if [ "$block" != "$first" ]; then
    echo "FAIL  profile block differs: $f vs $first_file"
    fails=$((fails + 1))
  fi
done

# The base copy wins; the working-tree copy is used only when the base has
# none (a project adopting a profile). Both matter: the first stops a diff from
# deleting, relocating or relaxing the gate it is being reviewed against.
profile_check() { # <repo> <label> <regex>...
  local repo=$1 label=$2 s out sh; shift 2
  for script in "$WORK"/*.sh; do
    s=$(basename "$script" .sh)
    for sh in bash zsh; do
      out=$(cd "$WORK/$repo" && GH_PR_BASE="" "$sh" "$script" 2>&1)
      for re in "$@"; do expect "$s [$label $sh]" "$out" "$re"; done
    done
  done
}

profile_check dirty "profile-none" '^REVIEW_PROFILE: none$' '^REVIEW_PROFILE_SOURCE: none$'
mkdir -p "$WORK/dirty/docs" && echo p > "$WORK/dirty/docs/review-profile.md"
profile_check dirty "profile-worktree" '^REVIEW_PROFILE: docs/review-profile\.md$' '^REVIEW_PROFILE_SOURCE: working tree \(base has no profile\)$'
mkdir -p "$WORK/dirty/.claude" && echo p > "$WORK/dirty/.claude/review-profile.md"
profile_check dirty "profile-precedence" '^REVIEW_PROFILE: \.claude/review-profile\.md$'

# No remote at all: the working-tree copy is usable but unverified.
mkdir -p "$WORK/noremote/docs" && echo p > "$WORK/noremote/docs/review-profile.md"
profile_check noremote "profile-no-remote" '^REVIEW_PROFILE: docs/review-profile\.md$' '^REVIEW_PROFILE_SOURCE: working tree \(base unavailable\)$'

# A profile committed on the base stays authoritative while a branch edits,
# deletes or relocates it.
git clone -q "$WORK/o.git" "$WORK/profile" 2>/dev/null
( cd "$WORK/profile" && git checkout -q -B dev origin/dev &&
  mkdir -p docs && echo p > docs/review-profile.md &&
  git add docs/review-profile.md && git commit -q -m profile && git push -q origin dev &&
  git checkout -q -B feat-profile origin/dev &&
  echo changed >> docs/review-profile.md && git add docs/review-profile.md && git commit -q -m edit )
profile_check profile "profile-base" '^BASE: dev$' '^REVIEW_PROFILE: origin/dev:docs/review-profile\.md$' '^REVIEW_PROFILE_SOURCE: base$'

# A base that cannot be fetched is read, but labelled as possibly stale.
git clone -q "$WORK/o.git" "$WORK/broken" 2>/dev/null
git -C "$WORK/broken" remote set-url origin "$WORK/missing.git"
profile_check broken "profile-fetch-failed" '^REVIEW_PROFILE: origin/dev:docs/review-profile\.md$' '^REVIEW_PROFILE_SOURCE: base \(fetch failed; may be stale\)$'

( cd "$WORK/profile" && git checkout -q -B feat-delete origin/dev &&
  git rm -q docs/review-profile.md && git commit -q -m delete )
profile_check profile "profile-deleted" '^REVIEW_PROFILE: origin/dev:docs/review-profile\.md$' '^REVIEW_PROFILE_SOURCE: base$'

( cd "$WORK/profile" && git checkout -q -B feat-relocate origin/dev &&
  mkdir -p .claude && git mv docs/review-profile.md .claude/review-profile.md &&
  git commit -q -m relocate )
profile_check profile "profile-relocated" '^REVIEW_PROFILE: origin/dev:docs/review-profile\.md$' '^REVIEW_PROFILE_SOURCE: base$'

# With both paths on the base, .claude/ wins there too -- even when the branch
# tries to remove docs/ and keep only its own copy.
( cd "$WORK/profile" && git checkout -q -B dev origin/dev &&
  mkdir -p .claude && echo p > .claude/review-profile.md &&
  git add .claude && git commit -q -m claude-profile && git push -q origin dev &&
  git checkout -q -B feat-both origin/dev &&
  git rm -q docs/review-profile.md && git commit -q -m drop-docs )
profile_check profile "profile-base-precedence" '^REVIEW_PROFILE: origin/dev:\.claude/review-profile\.md$' '^REVIEW_PROFILE_SOURCE: base$'

echo "$checks checks, $fails failed"
[ "$fails" -eq 0 ]
