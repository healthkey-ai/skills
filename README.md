# Skills

Shared Claude Code skills for HealthTree / HealthKey projects.

## Available Skills

| Skill | Description |
|-------|-------------|
| `code-review` | Full-stack code review against the base branch. Finds bugs, security issues, design problems. Auto-fixes mechanical issues, asks before design changes. Includes N+1 detection, DRY enforcement, frontend-as-presentation-layer checks. |
| `backend-review` | Deep Python / Django / DRF / Celery review. Catches N+1 queries, missing indexes, unsafe migrations, task timeout violations, serializer contract drift, and security issues. |
| `frontend-review` | React / Tailwind / shadcn/ui / React Query review. Catches anti-patterns, stale closures, cache misses, accessibility gaps, and Tailwind/shadcn misuse. |
| `infra-review` | GCP infrastructure and Terraform review for security, IAM, cost, reliability, and CI/CD best practices. |

## Install

```bash
# List available skills
./install.sh -l

# Install all skills into the current project
./install.sh

# Install specific skills into a project
./install.sh -t ~/my-app code-review backend-review

# Install globally (available in all projects on this machine)
./install.sh --global

# Install specific skills globally
./install.sh -g frontend-review infra-review

# Force overwrite without prompting
./install.sh -f
./install.sh -g -f
```

Skills are copied to `.claude/skills/<name>/SKILL.md` (project) or `~/.claude/skills/<name>/SKILL.md` (global).

Re-running the installer skips skills that are already up to date and prompts before overwriting changed ones (use `-f` to skip prompts).

## Usage

After installing, invoke a skill in Claude Code with its slash command:

```
/code-review
/backend-review
/frontend-review
/infra-review
```

Each skill accepts optional arguments:

```
/code-review #42              # review a specific PR
/backend-review apps/labs/    # scope to a directory
/infra-review full            # audit entire infra/ tree
```
