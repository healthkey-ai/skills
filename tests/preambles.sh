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
  local sh script s out label dir
  for sh in bash zsh; do
    for script in "$WORK"/*.sh; do
      s=$(basename "$script" .sh)
      dir="$WORK/case-$RANDOM$RANDOM"
      cp -R "$WORK/$repo" "$dir"
      git -C "$dir" checkout -q -B "$branch" "$from"
      mkdir -p "$dir/sub"
      out=$(cd "$dir/sub" && GH_PR_BASE="$pr" "$sh" "$script" 2>&1)
      label="$s [$sh] repo=$repo branch=$branch pr=${pr:-none}"
      expect "$label" "$out" "^BASE: ${want//./\\.}\$"
      if [ "$mb" = yes ]; then
        expect "$label" "$out" "^MERGE_BASE: [0-9a-f]{40}\$"
      else
        expect "$label" "$out" "^NO_BASE: true\$"
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

echo "$checks checks, $fails failed"
[ "$fails" -eq 0 ]
