# workflow-expert

Project-level Claude Code skill that owns the issue-to-deploy developer workflow for pronext.

See `SKILL.md` for the full command reference. Design spec: `docs/superpowers/specs/2026-04-18-workflow-expert-design.md`.

## One-time setup (per developer)

```bash
cd .claude/skills/workflow-expert
cp config.env.example config.env
# edit config.env, fill in any tokens you have access to
```

`config.env` is gitignored — each developer keeps personal tokens locally.

## Running the tests

```bash
.claude/skills/workflow-expert/tests/run_all.sh
```
