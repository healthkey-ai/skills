#!/usr/bin/env bash
set -euo pipefail

SKILLS_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [skill ...]

Install Claude Code skills into a target project or globally.

Options:
  -t, --target DIR   Target project directory (default: current directory)
  -g, --global       Install to ~/.claude/skills (available in all projects)
  -c, --check        Check installed skills for updates (no changes)
  -l, --list         List available skills and exit
  -f, --force        Overwrite existing skills without prompting
  -h, --help         Show this help

Arguments:
  skill ...          Skills to install (default: all)

Examples:
  $(basename "$0") -l
  $(basename "$0") -t ../ht-phr code-review backend-review
  $(basename "$0") --global
  $(basename "$0") -g frontend-review infra-review
  $(basename "$0") --check
  $(basename "$0") -g --check
EOF
  exit 0
}

get_version() {
  grep '^  version:' "$1" 2>/dev/null | head -1 | sed 's/^  version: *"//;s/"$//' || echo ""
}

get_source() {
  grep '^  source:' "$1" 2>/dev/null | head -1 | sed 's/^  source: *"//;s/"$//' || echo ""
}

get_description() {
  grep '^description:' "$1" 2>/dev/null | head -1 | sed 's/^description: *"//;s/"$//' || echo ""
}

list_skills() {
  printf "%-20s %-10s %-12s %s\n" "SKILL" "VERSION" "SOURCE" "DESCRIPTION"
  printf "%-20s %-10s %-12s %s\n" "-----" "-------" "------" "-----------"
  for dir in "$SKILLS_DIR"/*/; do
    [ ! -f "$dir/SKILL.md" ] && continue
    name=$(basename "$dir")
    printf "%-20s %-10s %-12s %s\n" "$name" "$(get_version "$dir/SKILL.md")" "$(get_source "$dir/SKILL.md")" "$(get_description "$dir/SKILL.md")"
  done
}

available_skills() {
  for dir in "$SKILLS_DIR"/*/; do
    [ -f "$dir/SKILL.md" ] && basename "$dir" || true
  done
}

check_skills() {
  local dest="$1"
  shift
  local skills=("$@")
  local outdated=0
  local missing=0
  local current=0

  for skill in "${skills[@]}"; do
    local src="$SKILLS_DIR/$skill/SKILL.md"
    local dst="$dest/$skill/SKILL.md"
    local repo_ver
    repo_ver=$(get_version "$src")

    if [ ! -f "$dst" ]; then
      printf "  missing   %-20s (available: %s)\n" "$skill" "$repo_ver"
      missing=$((missing + 1))
    elif diff -q "$src" "$dst" >/dev/null 2>&1; then
      printf "  current   %-20s %s\n" "$skill" "$repo_ver"
      current=$((current + 1))
    else
      local installed_ver
      installed_ver=$(get_version "$dst")
      printf "  outdated  %-20s (installed: %s, available: %s)\n" "$skill" "${installed_ver:-?}" "$repo_ver"
      outdated=$((outdated + 1))
    fi
  done

  echo ""
  echo "$current current, $outdated outdated, $missing not installed"
  if [ "$outdated" -gt 0 ] || [ "$missing" -gt 0 ]; then
    return 1
  fi
  return 0
}

# --- Parse arguments ---

TARGET="$(pwd)"
GLOBAL=false
FORCE=false
CHECK=false
SKILLS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)       TARGET="$2"; shift 2 ;;
    -g|--global)       GLOBAL=true; shift ;;
    -c|--check)        CHECK=true; shift ;;
    -l|--list)         list_skills; exit 0 ;;
    -f|--force)        FORCE=true; shift ;;
    -h|--help)         usage ;;
    -*)                echo "Unknown option: $1" >&2; usage ;;
    *)                 SKILLS+=("$1"); shift ;;
  esac
done

if [ "$GLOBAL" = true ]; then
  TARGET="$HOME"
fi
TARGET="$(cd "$TARGET" && pwd)"

if [ ${#SKILLS[@]} -eq 0 ]; then
  while IFS= read -r s; do
    SKILLS+=("$s")
  done < <(available_skills)
fi

AVAILABLE=$(available_skills)
for skill in "${SKILLS[@]}"; do
  if ! echo "$AVAILABLE" | grep -qx "$skill"; then
    echo "error: unknown skill '$skill'" >&2
    echo "available: $(echo "$AVAILABLE" | tr '\n' ' ')" >&2
    exit 1
  fi
done

if [ "$GLOBAL" = true ]; then
  DEST="$HOME/.claude/skills"
else
  DEST="$TARGET/.claude/skills"
fi

# --- Check mode ---

if [ "$CHECK" = true ]; then
  check_skills "$DEST" "${SKILLS[@]}"
  exit $?
fi

# --- Install mode ---

mkdir -p "$DEST"

installed=0
skipped=0
updated=0

for skill in "${SKILLS[@]}"; do
  src="$SKILLS_DIR/$skill/SKILL.md"
  dst="$DEST/$skill/SKILL.md"
  repo_ver=$(get_version "$src")

  if [ -f "$dst" ]; then
    if diff -q "$src" "$dst" >/dev/null 2>&1; then
      echo "  skip     $skill ($repo_ver, up to date)"
      skipped=$((skipped + 1))
      continue
    fi

    installed_ver=$(get_version "$dst")
    if [ "$FORCE" = false ]; then
      printf "  update   %s? (%s -> %s) (y/n) " "$skill" "${installed_ver:-?}" "$repo_ver"
      read -r answer
      if [[ "$answer" != [yY]* ]]; then
        echo "  skip     $skill"
        skipped=$((skipped + 1))
        continue
      fi
    fi

    mkdir -p "$DEST/$skill"
    cp "$src" "$dst"
    echo "  updated  $skill ($repo_ver)"
    updated=$((updated + 1))
  else
    mkdir -p "$DEST/$skill"
    cp "$src" "$dst"
    echo "  installed  $skill ($repo_ver)"
    installed=$((installed + 1))
  fi
done

echo ""
echo "done: $installed installed, $updated updated, $skipped skipped"
echo "target: $DEST"
