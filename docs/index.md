# INMANAGE – Full Documentation

This document complements the README with more detail about setup, configuration, commands, and operational practices.

## Installation Modes
- **System (global):** Installs to `/usr/local/share/inmanage`, symlinks `/usr/local/bin/{inmanage,inm}`. Requires sudo.
- **User:** Installs to `~/.inmanage_app`, symlinks `~/.local/bin/{inmanage,inm}`. No sudo.
- **Project:** Installs to `../.inmanage_app` with config in `../.inmanage/` relative to the project. Local symlinks `./inmanage`, `./inm`.

Run the installer once:  
`curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | bash`  
It prompts for mode and, if needed, sudo password.

## Configuration Files
- **Project config:** `.inmanage/.env.inmanage` (kept outside the app). Generated on first run or via prompts.
- **Provision config (unattended installs):** `.inmanage/.env.provision` (spawn via `inmanage core provision spawn`, then edit).
- **App env:** `<install>/ .env` (standard Invoice Ninja env). Path typically `<base>/<install>/.env`.

Important keys to keep in provision/self config: `INM_ENFORCED_USER`, `INM_ENFORCED_SHELL`, `INM_BASE_DIRECTORY`, `INM_INSTALLATION_DIRECTORY`, `INM_ENV_FILE`, backup/cache paths.

## Install / Provision Flow
1) Install CLI (mode prompt via installer).  
2) `cd` into Invoice Ninja base directory.  
3) Run `inmanage core install` and choose:
   - **Provisioned (recommended):** uses `.inmanage/.env.provision` (spawn + edit) → unattended install, seeds defaults.
   - **Clean:** deploys vanilla app; complete setup in the browser or reuse an existing `.env` + imported DB.
Direct flags: `--provision`, `--install-mode=system|user|project`, `--provision-env=<path>`.

## Updates
- App: `inmanage core update [--version=v] [--force]`
  - Safe move/copy, keeps backup of previous install.
  - Downloads are checksum-verified against GitHub release digest; use `--bypass-check-sha=true` to skip if needed.
- CLI: `inmanage self update` (git pull) or rerun the installer for your mode.

## Backups and Restore
- Full backup (db + storage + uploads; optional app + extra paths):
  ```
  inmanage core backup --name=label --compress=tar.gz --include-app=true --extra-paths=path1,path2
  ```
- DB-only or files-only: `inmanage db backup ...`, `inmanage files backup ...`.
- Restore from bundle: `inmanage core restore --file=path [--include-app=true|false] [--target=/path] [--force]`.
  - Picks latest bundle if `--file` omitted.
  - Use `--include-app=false` for DB/storage/uploads only.
- Checksums: backups emit SHA256 files; verify integrity on restore.

## Prune / Cleanup
- `inmanage core prune` (versions/backups/cache), or specific: `prune-versions`, `prune-backups`.
- Aliases exist in `db/files` contexts for pruning backups.

## Health / Preflight
- `inmanage core health` (alias `info`): checks CLI, system, commands, network, web, PHP/EXT, web PHP, FS, DB, cron, snappdf.
- Flags: `--fast`, `--skip-db`, `--skip-github`, `--skip-snappdf`, `--skip-web-php`.
- Output includes aggregate status and per-section tables.

## Cron
- `inmanage cron install` to install cronjobs for artisan schedule and backups.
- Manual examples are in README (cron.d or crontab style).

## Environment Helpers
- `inmanage env set|get|unset|show` to manipulate the app `.env`.

## Provision File
- Generate: `inmanage core provision spawn`.
- Edit `.inmanage/.env.provision` for target DB/APP_URL/user/etc.
- Install: `inmanage core install --provision`.

## Cache and Downloads
- Global cache default: `${INM_CACHE_GLOBAL_DIRECTORY}` (e.g., `/usr/share/nginx/.../.cache/inmanage`), falls back to local `${INM_CACHE_LOCAL_DIRECTORY}` (e.g., `./.cache`).
- Downloads:
  - Verify release digest from GitHub (if available).
  - Resume partial downloads (`.part` files).
  - Use `--bypass-check-sha=true` to skip digest checks if needed.
  - Provide `INM_GH_API_CREDENTIALS=token:<PAT>` to avoid rate limits and speed up GitHub requests.

## Self Commands
- `inmanage self install` (mode prompts) – installs CLI.
- `inmanage self update` – git pull updates.
- `inmanage self switch-mode` – reinstall in another mode; can clean old symlinks/dirs.
- `inmanage self uninstall` – remove symlinks; optional delete install dir (`--force`).

## Tips & Tricks
- Prefer provisioned installs: generate `.inmanage/.env.provision`, edit once, then `inmanage core install --provision` for repeatable staging/prod rollouts.
- Use `--fast` (or `--skip-web-php` / `--skip-db`) for quick health checks; run full `core health` before upgrades.
- Set `INM_GH_API_CREDENTIALS=token:<PAT>` to avoid GitHub rate limits and speed up downloads; check limits with `curl https://api.github.com/rate_limit`.
- If the global cache is unwritable, point to a local cache via config or `--cache-dir=./.cache`; downloads resume automatically from `.part` files.
- Dry-run everything first: `--dry-run` shows moves/backups/restore steps without writing.
- Name backups: `--name=<label>` (e.g., `pre_migration`) and include custom paths with `--extra-paths=path1,path2`.
- Selective restore: `--include-app=false` restores only DB/storage/uploads when app code is already present.
- Cron: `inmanage cron install` asks for user/paths; in Docker, consider host cron that execs into the container.
- Snappdf runs only if `PDF_GENERATOR=snappdf` is set; if not reachable, skip with `--skip-snappdf` during health.
- In containers, give the target user a shell (`usermod -s /bin/bash www-data`) and ensure mounts are writable before running commands.

## Docker / Container Notes
- Script detects container; ensure correct mounts and enforce user/shell for artisan/cron.
- If app/base dirs are bind-mounted, prefer copy fallback (`safe_move_or_copy_and_clean`) already in use for updates.

## Error Handling / Bypass
- `--bypass-check-sha=true` to ignore release digest verification (only if hashes problematic).
- `--debug` for verbose logs; `--dry-run` to log intended actions without changes (where implemented).

## Troubleshooting Quick Tips
- Missing config: regenerate `.inmanage/.env.inmanage` (delete/recreate via prompts).
- Cache issues: ensure cache dirs are writable (777 attempted); check ownership if running as enforced user.
- Rate limits: set `INM_GH_API_CREDENTIALS` to a PAT.
- Slow/partial downloads: resume is automatic via `.part`; progress visible on TTY or with `--debug`.
