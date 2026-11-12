# Skills

Shared Claude Code review skills for Django/DRF/Celery + React/Tailwind/shadcn projects on GCP. Project-agnostic — each skill reads the target project's CLAUDE.md for conventions.

## Available Skills

| Skill | Version | Source | Description |
|-------|---------|--------|-------------|
| `hk-code-review` | 1.2.0 | shared | Full-stack code review against the base branch. Finds bugs, security issues, design problems. Offers mechanical fixes (applied on approval, or immediately with `--fix`), asks before design changes. |
| `hk-backend-review` | 1.2.0 | shared | Deep Python / Django / DRF / Celery review. Catches N+1 queries, missing indexes, unsafe migrations, task timeout violations, serializer contract drift. |
| `hk-frontend-review` | 1.2.0 | shared | React / Tailwind / shadcn/ui / React Query review. Catches anti-patterns, stale closures, cache misses, accessibility gaps. |
| `hk-infra-review` | 1.2.0 | shared | GCP infrastructure and Terraform review for security, IAM, cost, reliability, and CI/CD best practices. |

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

### Preamble Tests

The bash preamble of each skill is run by the agent's shell, which may be bash or zsh.
`tests/preambles.sh` runs every preamble under both against throwaway git repos
(stale `origin/HEAD`, single-branch clone, PR bases like `release/1.2`, no remote)
and checks the base branch it resolves. Run it after changing a preamble:

```bash
tests/preambles.sh
```

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
/hk-code-review                  # working tree vs. the base (open PR's base, else origin's default branch)
/hk-code-review #42              # review a specific PR
/hk-code-review dev..HEAD        # review an explicit range (committed changes only)
/hk-backend-review apps/<app>/   # scope to a directory
/hk-infra-review full            # audit entire infra/ tree
/hk-frontend-review --fix        # apply mechanical fixes without asking
```

Reviews never edit files unless you approve the proposed fixes or pass `--fix`.

## Metadata

Each SKILL.md has `version` and `source` under `metadata:` in its frontmatter — no separate manifest file needed.
