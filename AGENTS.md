# INmanage Agent Notes

Read this file before changing the repository, and reread it after context compression or handoff. Keep changes governance- and evidence-based: inspect the relevant help/docs/code first, then make the smallest change that fits the existing Bash CLI style.

## Where Things Are

- `readme.md`: public overview, quickstart, help entry points.
- `docs/index.md`: full documentation and the CLI help source of truth. The `CLI_HELP:*` blocks are read by the CLI at runtime; edit them when command help changes.
- `cheatsheet.md`: compact operator command reference.
- `inmanage.sh`: main CLI entrypoint, argument handling, dispatch.
- `install_inmanage.sh`: installer for system/user/project modes.
- `lib/core/`: core CLI modules such as config, checks, and command behavior.
- `lib/helpers/`: shared Bash helpers for env parsing, filesystem operations, prompts, preflight, notifications, and compatibility.
- `templates/`: generated helper scripts and operator templates.
- `scripts/selftest.sh`: user-POV validation runner.

## Working Rules

- Prefer current project wording and command names over inventing new terminology.
- Treat CLI help as an operator contract. If behavior or flags change, update `docs/index.md` help blocks and the public docs together.
- Before documenting a command, verify it with `./inmanage.sh -h` or `./inmanage.sh <context> <action> -h` when possible.
- For documentation-only changes, use narrow validation first. Useful checks include `./inmanage.sh -h` and targeted action help.
- If code changes are required, use Ponytail and write comprehensive tests for the changed behavior and affected risk surface. Include operator-facing validation such as targeted CLI help, relevant command dry-runs, and `scripts/selftest.sh --quick` or a broader selftest run when the environment can run it.
- Do not run destructive install/update/restore flows against a real Invoice Ninja instance unless the user explicitly asks for that.
- Preserve compatibility with the short command `inm` and direct repo execution via `./inmanage.sh`.
