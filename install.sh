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
  $(basename "$0") --force
EOF
  exit 0
}

list_skills() {
  printf "%-20s %s\n" "SKILL" "DESCRIPTION"
  printf "%-20s %s\n" "-----" "-----------"
  for dir in "$SKILLS_DIR"/*/; do
    [ ! -f "$dir/SKILL.md" ] && continue
    name=$(basename "$dir")
    desc=$(grep '^description:' "$dir/SKILL.md" | head -1 | sed 's/^description: *"//;s/"$//')
    printf "%-20s %s\n" "$name" "$desc"
  done
}

available_skills() {
  for dir in "$SKILLS_DIR"/*/; do
    [ -f "$dir/SKILL.md" ] && basename "$dir"
  done
}

TARGET="$(pwd)"
GLOBAL=false
FORCE=false
SKILLS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target) TARGET="$2"; shift 2 ;;
    -g|--global) GLOBAL=true; shift ;;
    -l|--list)   list_skills; exit 0 ;;
    -f|--force)  FORCE=true; shift ;;
    -h|--help)   usage ;;
    -*)          echo "Unknown option: $1" >&2; usage ;;
    *)           SKILLS+=("$1"); shift ;;
  esac
done

if [ "$GLOBAL" = true ]; then
  TARGET="$HOME"
fi
TARGET="$(cd "$TARGET" && pwd)"

if [ ${#SKILLS[@]} -eq 0 ]; then
  mapfile -t SKILLS < <(available_skills)
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
mkdir -p "$DEST"

installed=0
skipped=0
updated=0

for skill in "${SKILLS[@]}"; do
  src="$SKILLS_DIR/$skill/SKILL.md"
  dst="$DEST/$skill/SKILL.md"

  if [ -f "$dst" ]; then
    if diff -q "$src" "$dst" >/dev/null 2>&1; then
      echo "  skip  $skill (already up to date)"
      skipped=$((skipped + 1))
      continue
    fi

    if [ "$FORCE" = false ]; then
      printf "  update %s? (y/n) " "$skill"
      read -r answer
      if [[ "$answer" != [yY]* ]]; then
        echo "  skip  $skill"
        skipped=$((skipped + 1))
        continue
      fi
    fi

    mkdir -p "$DEST/$skill"
    cp "$src" "$dst"
    echo "  updated  $skill"
    updated=$((updated + 1))
  else
    mkdir -p "$DEST/$skill"
    cp "$src" "$dst"
    echo "  installed  $skill"
    installed=$((installed + 1))
  fi
done

echo ""
echo "done: $installed installed, $updated updated, $skipped skipped"
echo "target: $DEST"
