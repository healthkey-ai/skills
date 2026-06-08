# Skills

Shared Claude Code review skills for Django/DRF/Celery + React/Tailwind/shadcn projects on GCP. Project-agnostic — each skill reads the target project's CLAUDE.md for conventions.

## Available Skills

| Skill | Version | Source | Description |
|-------|---------|--------|-------------|
| `hk-code-review` | 1.1.0 | shared | Full-stack code review against the base branch. Finds bugs, security issues, design problems. Auto-fixes mechanical issues, asks before design changes. |
| `hk-backend-review` | 1.1.0 | shared | Deep Python / Django / DRF / Celery review. Catches N+1 queries, missing indexes, unsafe migrations, task timeout violations, serializer contract drift. |
| `hk-frontend-review` | 1.1.0 | shared | React / Tailwind / shadcn/ui / React Query review. Catches anti-patterns, stale closures, cache misses, accessibility gaps. |
| `hk-infra-review` | 1.1.0 | shared | GCP infrastructure and Terraform review for security, IAM, cost, reliability, and CI/CD best practices. |

## Install

```bash
# List available skills with versions
./install.sh -l

# Install all skills into the current project
./install.sh

# Install specific skills into a project
./install.sh -t ~/my-app hk-code-review hk-backend-review

# Install globally (available in all projects on this machine)
./install.sh --global

# Install specific skills globally
./install.sh -g hk-frontend-review hk-infra-review

# Force overwrite without prompting
./install.sh -f
./install.sh -g -f
```

Skills are copied to `.claude/skills/<name>/SKILL.md` (project) or `~/.claude/skills/<name>/SKILL.md` (global).

Re-running the installer skips skills that are already up to date and prompts before overwriting changed ones (use `-f` to skip prompts).

## Version Check

Check if installed skills are up to date without making changes:

```bash
# Check current project
./install.sh --check

# Check global skills
./install.sh -g --check

# Check a specific project
./install.sh --check -t ~/my-app
```

Exit code: `0` = all current, `1` = updates available.

## Development

### Pre-Commit Hook

A pre-commit hook validates skills consistency before committing to this repo:

- Every skill directory has a `SKILL.md`
- Every `SKILL.md` has valid frontmatter starting at line 1
- Required fields: `name`, `description`, `metadata.version`, `metadata.source`
- `name` matches the directory name

Install:

```bash
ln -sf ../../hooks/pre-commit .git/hooks/pre-commit
```

## Usage

After installing, invoke a skill in Claude Code with its slash command:

```
/hk-code-review
/hk-backend-review
/hk-frontend-review
/hk-infra-review
```

Each skill accepts optional arguments:

```
/hk-code-review #42              # review a specific PR
/hk-backend-review apps/<app>/   # scope to a directory
/hk-infra-review full            # audit entire infra/ tree
```

## Metadata

Each SKILL.md has `version` and `source` under `metadata:` in its frontmatter — no separate manifest file needed.
