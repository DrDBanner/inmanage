# INMANAGE Documentation

Inmanage is the CLI for self-hosted Invoice Ninja. Focus: **convenience**, **certainty**, **low stress**. This document keeps the flow simple while staying complete.

## Table of contents

- [Mental model](#mental-model)
- [Files you should know](#files-you-should-know)
- [Invoice Ninja CLI](#invoice-ninja-cli)
  - [Install CLI](#install-cli)
  - [Switch branches later](#switch-branches-later)
  - [CLI updates](#cli-updates)
- [First run](#first-run)
- [Global switches](#global-switches)
- [Hooks (pre/post)](#hooks-prepost)
- [Install Invoice Ninja](#install-invoice-ninja)
  - [Provisioned install (recommended)](#provisioned-install-recommended)
  - [Install flow (under the hood)](#install-flow-under-the-hood)
  - [Wizard install](#wizard-install)
  - [Clean/forced install](#cleanforced-install)
- [Updates](#updates)
- [Uninstall and reinstall](#uninstall-and-reinstall)
- [Backups](#backups)
- [Restore](#restore)
- [Health checks](#health-checks)
- [Cron](#cron)
- [Notification system (heartbeat)](#notification-system-heartbeat)
- [Environment helper](#environment-helper)
- [Cache and downloads](#cache-and-downloads)
- [Database client selection](#database-client-selection)
- [Debugging](#debugging)
- [Sudo usage](#sudo-usage)
- [FAQ](#faq)
- [Troubleshooting (short)](#troubleshooting-short)
- [Docker notes](#docker-notes)
  - [Docker backups with backup_remote_job.sh](#docker-backups-with-backup_remote_jobsh)
- [libSaxon (XSLT2) for e‑invoicing](#libsaxon-xslt2-for-einvoicing)

## Mental model

- **Base directory**: the folder that contains your Invoice Ninja app folder.
- **Install directory**: the app folder itself (default: `./invoiceninja`).
- **CLI config** lives in `.inmanage/` next to your app, not inside it.

## Files you should know

- `.inmanage/.env.inmanage` — CLI config (generated on first run)
- `.inmanage/.env.provision` — provisioned install config (unattended)
- `<install>/.env` — Invoice Ninja app config

## Invoice Ninja CLI

### Install CLI

Quick install (auto mode):

```bash
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | bash
```

Auto mode picks **system** when run as root, otherwise **user**, and creates symlinks (`inm`, `inmanage`) when possible.

Default paths:
- System (sudo): `/usr/local/share/inmanage` → `/usr/local/bin`
- User: `~/.local/share/inmanage` → `~/.local/bin`
- Project (run in base dir): `./.inmanage/cli` → project root

Common installs:

```bash
# Project install (simple)
cd /path/to/your/invoiceninja_basedirectory
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | bash -s -- --mode project
```

```bash
# System install (simple)
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | sudo bash
```

```bash
# System install with ownership/permissions (optional)
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | sudo bash -s -- --mode system --install-owner=root:vuser --install-perms=775:664
```

> [!TIP]
> If `inm` is not found after a user install, add `~/.local/bin` to `PATH`:
> `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.profile`

> [!NOTE]
> * `sudo -u <user> inm ...` runs the command as that OS user now.
> * `--run-user <user>` is for install mode only (it sets who owns/should run the CLI after install).

Installer options (`install_inmanage.sh`):

| Switch | Default | Description |
| --- | --- | --- |
| `--mode system / user / project` | auto | Install mode (system when run as root, otherwise user). |
| `--target DIR` | mode default | Install directory. |
| `--symlink-dir DIR` | mode default | Where to place `inm`/`inmanage` symlinks. |
| `--install-owner USER:GROUP` | unset | Set ownership on install directory (system installs). |
| `--install-perms DIR:FILE` | unset | Set permissions on install directory (e.g. `775:664`). |
| `--run-user USER` | auto | User that will run CLI/cron tasks (used for user installs). |
| `--branch BRANCH` | fetched branch | Git branch to install. |
| `--source PATH` | unset | Use an existing checkout instead of git cloning. |
| `-h` / `--help` | | Show installer help. |

Installer env vars mirror the switches:
`BRANCH`, `INSTALLER_BRANCH`, `MODE`, `TARGET_DIR`, `SYMLINK_DIR`, `INSTALL_OWNER`, `INSTALL_PERMS`, `RUN_USER`, `SOURCE_DIR`.

Use `--source` when you already have a local checkout (e.g. mounted dev workspace or offline/air‑gapped install).

#### Install from a different branch

Install from `development` (add `sudo` for system installs or `--mode system|user|project`):

```bash
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/development/install_inmanage.sh | BRANCH=development bash
```

You can also pass the branch flag explicitly:

```bash
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/development/install_inmanage.sh | sudo bash -s -- --branch development --mode system
```

### Switch branches later

If you installed from a git checkout, re-run the installer with a new branch:

```bash
sudo BRANCH=development bash install_inmanage.sh --branch development --mode system
```

Manual git switch (system install path shown):

```bash
cd /usr/local/share/inmanage
git fetch origin
git checkout development
git pull --ff-only
```

Note: `inm self update` only pulls the current branch; it does not switch branches.

### CLI updates

```bash
inm self update
```

For system-wide CLI installs, run:

```bash
sudo inm self update
# or
sudo -u <user> inm self update
```

## First run

Run from your base directory. On first run, `inm` will prompt to create `.inmanage/.env.inmanage` (and its folders) if it does not exist. `inm health` can run without a config; most other commands will prompt you to create one when needed.

```bash
sudo -u www-data inm
```

If `sudo` isn't needed:

```bash
inm
```

> [!NOTE]
> On first run, use the user who should read/write the Invoice Ninja files (often the webserver user; on shared hosting, your login user). This prevents permission issues. If you later switch users, update `INM_ENFORCED_USER` in `.env.inmanage`.

## Global switches

| Switch | Default | Description |
| --- | --- | --- |
| `--force` | `false` | Skip confirmations for destructive operations (required for provisioned install and DB restore). |
| `--debug` | `false` | Verbose output for troubleshooting. |
| `--dry-run` | `false` | Show planned actions without changing anything. |
| `--override-enforced-user` | `false` | Skip enforced user switch for this run. |
| `--no-cli-clear` | `false` | Keep terminal output (skip clear + logo). |
| `--ninja-location=path` | unset | Use a specific app directory (must contain `.env`). |
| `--config=path` | unset | Use a specific CLI config file (`.env.inmanage`). |
| `--config-root=dir` | `.inmanage` | Override the CLI config directory root. |
| `--auto-create-config=true/false` | `false` | Auto‑persist derived CLI config when missing. |
| `--auto-select=true/false` | `false` | Auto‑select defaults when no TTY is available. |
| `--select-timeout=secs` | `60` | Timeout for interactive selections (seconds). |


Permissions defaults (CLI config, used by `--fix-permissions`):
- `INM_ENFORCED_USER` and optional `INM_ENFORCED_GROUP` for ownership.
- `INM_DIR_MODE` for app directories (default `750`).
- `INM_FILE_MODE` for app files (default `640`, skips executable files).
- `INM_ENV_MODE` for app `.env` (default `600`).
- `INM_CACHE_DIR_MODE` / `INM_CACHE_FILE_MODE` for cache permissions (defaults: 775/664 when a group is set, otherwise 750/640).

## Hooks (pre/post)

You can plug your own scripts into the flow.

Default hook location:

- `.inmanage/hooks/<event>`

Override via environment:

- `INM_HOOK_PRE_INSTALL=/path/to/script`
- `INM_HOOK_POST_INSTALL=/path/to/script`
- `INM_HOOK_PRE_UPDATE=/path/to/script`
- `INM_HOOK_POST_UPDATE=/path/to/script`
- `INM_HOOK_PRE_BACKUP=/path/to/script`
- `INM_HOOK_POST_BACKUP=/path/to/script`

Optional:

- `INM_HOOKS_DIR=/custom/hooks/dir` (changes the default hook directory)
- `INM_HOOK_STRICT=true` (fail on *any* hook error, including post hooks)

Behavior:

- `pre-*` hooks **abort** on non‑zero exit.
- `post-*` hooks **warn** and continue (unless `INM_HOOK_STRICT=true`).
- Hooks are skipped in `--dry-run`.
- Non-executable hook files are run via `bash`.

Hooks run with these env vars set:

- `INM_HOOK_EVENT` (e.g. `pre-install`)
- `INM_HOOK_STAGE` (`pre` / `post`)
- `INM_HOOK_NAME` (`install` / `update` / `backup`)
- `INM_HOOK_SCRIPT` (resolved hook path)

Example: post-install hook to inject custom app keys:

```bash
#!/usr/bin/env bash
set -e

# in .inmanage/hooks/post-install
inm env set app CUSTOM_FEATURE_FLAG true
inm env set app CUSTOM_BRANDING_NAME "Acme Co"
```

## Install Invoice Ninja

### Provisioned install (recommended)

Repeatable and unattended. Best for staging/production.

> [!WARNING]
> Provisioned installs are **destructive** (app + DB). A backup is created by default. `--force` is required for non‑wizard runs to confirm the risk; the wizard handles confirmation interactively. Avoid `--no-backup` unless you fully understand the impact.

1. Generate a provision file with the wizard:
   ```bash
   inm core install
   ```
   The wizard offers to create `.env.provision` and opens it in your default editor (nano/vi).

   > [!NOTE]
   > Manual alternative:
   > ```bash
   > inm core provision spawn
   > ```
   > `spawn` creates a ready-to-edit `.env.provision` from the bundled `.env.example` (or app `.env` if present).
2. If you already have a prepared `.env.provision`, place it in `.inmanage/.env.provision`.
   - `DB_ELEVATED_USERNAME` and `DB_ELEVATED_PASSWORD` are only used to create the DB/user if needed and are removed after success.
3. Execute installation:
   ```bash
   inm core install --provision
   ```

Install switches (`inm core install`):

| Switch | Default | Description |
| --- | --- | --- |
| `--provision` | `false` | Use provisioned install with `.inmanage/.env.provision` (recommended). |
| `--clean` | `false` | Deploy a fresh app. Wizard installs still require the web setup afterward (time consuming). |
| `--force` | `false` | Required for provisioned installs (destructive). |
| `--no-backup` | `false` | Skip pre-provision DB backup (provisioned install only). |
| `--no-cron-install` | `false` | Skip cron installation (useful if you manage cron yourself). |
| `--cron-mode=auto / system / crontab` | `auto` | Force cron install mode. `auto` chooses system cron if possible, otherwise user crontab. |
| `--cron-jobs=artisan / backup / heartbeat / essential / both / all` | `both` | Which cron jobs to install during setup. |
| `--no-backup-cron` | `false` | Skip the backup cron job during setup. |
| `--backup-time=HH:MM` | `03:24` | Backup cron schedule (24h). |
| `--heartbeat-time=HH:MM` | `06:00` | Heartbeat cron schedule (24h). |
| `--bypass-check-sha` | `false` | Skip release digest verification (not recommended). |
| `--version=v` | latest | Reserved: install currently uses latest release. |

Provision spawn switches (`inm core provision spawn`):

| Switch | Default | Description |
| --- | --- | --- |
| `--provision-file=path` | `.inmanage/.env.provision` | Where to write the provision file. |
| `--backup-file=path` | unset | Use a specific migration backup after install. |
| `--latest-backup` | `false` | Use the latest backup after install. |
| `--force` | `false` | Overwrite an existing provision file. |

> [!NOTE]
> - A clean `.env.example` is bundled and used to seed `.env.provision`.
> - `DB_ELEVATED_USERNAME` / `DB_ELEVATED_PASSWORD` are required only if the script should create the DB/user; otherwise the DB must already exist and match the `DB_*` values.
> - Elevated credentials are removed from `.env.provision` after a successful provision.
> - Migration restore can also be driven by `INM_MIGRATION_BACKUP` in `.env.provision` or `.env.inmanage` (set to `LATEST` or a backup path).

Migration flow (provisioned install):

1. Create a migration backup on the source host:
   ```bash
   inm core backup --name=migration --compress=tar.gz --include-app=true
   ```
   Preferred: write target-ready values into the backup `.env` so the restore can run without manual edits later. The command prompts you for APP_URL and DB values (and optionally extra keys), writes them into the backup bundle (APP_KEY is preserved), and the restored app will use those values immediately.
   ```bash
   inm core backup --create-migration-export
   ```
2. On the target host, point provision to the backup:
   - `inm core provision spawn --backup-file=/path/to/backup.tar.gz`
   - or `inm core provision spawn --latest-backup`
   - or set `INM_MIGRATION_BACKUP=LATEST` (or a path) in `.env.provision` / `.env.inmanage`

### Install flow (under the hood)

Shared steps (both provisioned and clean):

- Resolve base/app paths and load CLI/app config.
- Optional hooks: `pre-install`.
- Archive existing app directory if present.
- Download the Invoice Ninja release into cache.
- Fetch release digest and verify the tarball checksum (fails if missing, unless you explicitly bypass).
- Extract into a temp directory.
- Stage extracted files into `<install>_temp` and switch to the install path via move when possible, otherwise copy with cleanup (safe move/copy).
- Deploy the new app into the install path and enforce ownership/permissions (if configured).
- Run artisan tasks: `key:generate`, `optimize`, `up`, `ninja:translations`, snappdf setup.
- Optional cron install (configurable).
- Optional hooks: `post-install`.
- Final cache cleanup: `config:clear` + `cache:clear`.

Provisioned‑only steps:

- Place `.env` from `.env.provision` (remove the inm header block).
- If tables exist, require confirmation (`--force` or prompt) because it is destructive.
- Pre‑provision DB backup if tables exist (unless `--no-backup`).
- Create DB/user if needed (`DB_ELEVATED_*`), then `migrate:fresh --seed`.
- Language seeder + `ninja:post-update` + create admin user.
- Optional migration restore if `INM_MIGRATION_BACKUP` is set.

Clean‑only steps:

- Place a default, unconfigured `.env` for the web wizard to fill in.

Mandatory settings to review (common):

- `APP_URL`
- `DB_PASSWORD`
- `DB_ELEVATED_USERNAME`
- `DB_ELEVATED_PASSWORD`
- `PDF_GENERATOR=snappdf` (if you use Snappdf)
- Mail settings: `MAIL_HOST`, `MAIL_PORT`, `MAIL_USERNAME`, `MAIL_PASSWORD`, `MAIL_ENCRYPTION`, `MAIL_FROM_ADDRESS`, `MAIL_FROM_NAME`

Optional: set any other Invoice Ninja `.env` keys you need. Official env reference:
<https://invoiceninja.github.io/en/self-host-installation/#configure-environment>

### Wizard install

Starts the wizard and lets you choose between provisioned and clean install:

```bash
inm core install
```

For **clean** installs, the wizard drops a default `.env`. You must complete the web setup to write DB/app values, then manually review `.env` for settings the GUI doesn’t cover.

### Clean/forced install

```bash
inm core install --clean
```

Clean install deploys a fresh app. If an app already exists, it is archived first (same behavior as other install modes).

> [!WARNING]
> A clean install replaces the app code (DB stays). Use only if you can tolerate downtime and have a rollback plan.

## Updates

```bash
inm core update
```

- Updates keep the previous version for rollback side by side with the app directory; DB backups land in the backup directory, since DB rollback is needed less often.
- Uses less RAM than web-based updates, especially on small servers.


Update switches (`inm core update`):

| Switch | Default | Description |
| --- | --- | --- |
| `--version=v` | latest | Install a specific Invoice Ninja version. |
| `--force` | `false` | Allow downgrade and skip confirmation prompts. |
| `--cache-only` | `false` | Download package to cache only (no install). |
| `--preserve-paths=a,b` | unset | Extra paths to preserve from the previous install (comma‑separated, relative to app root). Env: `INM_PRESERVE_PATHS`. |
| `--no-db-backup` | `false` | Skip the mandatory pre-update DB backup (not recommended). |
| `--bypass-check-sha` | `false` | Skip release digest verification (not recommended). |

Update flow (under the hood):

- Read current version and resolve target version.
- Create a pre‑update DB backup (unless `--no-db-backup`).
- Download target release into cache.
- Fetch release digest and verify the tarball checksum (fails if missing, unless you explicitly bypass).
- Extract into a temp directory.
- Prepare a new version directory and copy preserved paths.
- Move current app to a rollback directory.
- Activate the new version via move when possible, otherwise copy with cleanup (safe move/copy).
- Enforce ownership/permissions (if configured).
- Run artisan tasks: `migrate --force`, `optimize`, `ninja:post-update`, `ninja:check-data`, `ninja:translations`, `ninja:design-update`, `up`.
- Snappdf setup (if enabled).
- Cleanup cached versions and old rollbacks (per retention settings).

Rollback:

```bash
inm update rollback last
inm update rollback invoiceninja_rollback_YYYYMMDD_HHMMSS
```
Rollback swaps the current app with the selected rollback directory and reuses the existing DB (no DB rollback is applied).

## Uninstall and reinstall

Remove the current install:

```bash
inm self uninstall
```

> [!WARNING]
> `--force` is **destructive** and removes the install directory for the active install mode (system/user/project), plus its symlinks.
> It does **not** touch your Invoice Ninja app installation.

Common examples:

```bash
# User install
inm self uninstall --force
```

```bash
# System install
sudo inm self uninstall --force
```

```bash
# Project install (from project root)
./inm self uninstall --force
```

If you had multiple installs, uninstalling one does **not** remove the others. To switch back, remove the local `./inm` symlink (project mode), ensure the desired `PATH` entry is present, then run `hash -r` or open a new shell. Use `which inm` to confirm.

Reinstall by running the installer again (see [Install CLI](#install-cli)).

## Backups

Full bundle (db + storage + uploads; optional app + extras):

```bash
inm core backup --name=pre_migration --compress=tar.gz --include-app=true --extra-paths=custom1,custom2
```

Backup switches (`inm core backup`):

| Switch | Default | Description |
| --- | --- | --- |
| `--compress=tar.gz / zip / false` | `tar.gz` | Bundle format; `false` creates a directory. |
| `--name=label` | unset | Label in filename; timestamp is appended if the label has no date. |
| `--include-app=true/false` | `true` | Include application code in the bundle. |
| `--bundle=true/false` | `true` | `true` = single bundle; `false` = multi-part outputs. |
| `--db=true/false` | `true` | Include DB dump. |
| `--storage=true/false` | `true` | Include `storage/`. |
| `--uploads=true/false` | `true` | Include `public/uploads/`. |
| `--fullbackup=true/false` | `true` | Force full bundle (db+storage+uploads). |
| `--extra-paths=a,b` | unset | Add extra paths (comma‑separated). Relative paths resolve from app dir; absolute paths are allowed. Alias: `--extra`. |
| `--create-migration-export` | `false` | Prompt for APP_URL + DB_* and write them into the backup `.env` (APP_KEY preserved); optionally add extra keys. |

DB-only and files-only backups:

```bash
inm db backup --name=label
inm files backup --name=label
```

These commands accept the same switches as above, but the defaults are scoped:
- `db backup` forces DB-only.
- `files backup` defaults to app + storage + uploads (DB off). Use `--include-app=false` to exclude the app files.

Files backup switches (`inm files backup`):

| Switch | Default | Description |
| --- | --- | --- |
| `--compress=tar.gz / zip / false` | `tar.gz` | Bundle format; `false` creates a directory. |
| `--name=label` | unset | Label in filename; timestamp is appended if the label has no date. |
| `--include-app=true/false` | `true` | Include application code in the backup. |
| `--bundle=true/false` | `true` | `true` = single bundle; `false` = multi-part outputs. |
| `--storage=true/false` | `true` | Include `storage/`. |
| `--uploads=true/false` | `true` | Include `public/uploads/`. |
| `--extra-paths=a,b` | unset | Add extra paths (comma‑separated). Relative paths resolve from app dir; absolute paths are allowed. Alias: `--extra`. |

## Restore

```bash
inm core restore --file=path --force
```

> [!WARNING]
> Restore can overwrite app files and **drop/import DB tables**. Always verify the target and keep a backup.

> [!TIP]
> `--pre-backup=true` (default) keeps a pre-restore copy of the current app so you can roll back quickly.

Restore switches (`inm core restore`):

| Switch | Default | Description |
| --- | --- | --- |
| `--file=path` | unset | Path to bundle/dir to restore (alias: `--bundle`). |
| `--force` | `false` | Required for destructive operations (DB import). |
| `--include-app=true/false` | `true` | Restore application files. |
| `--target=path` | app dir | Restore target directory (alias: `--bundle-target`). |
| `--pre-backup=true/false` | `true` | Move current app to a pre-restore backup. |
| `--purge=true/false` | `true` | Drop existing DB tables before import (alias: `--purge-db`). |
| `--autofill-missing=1/0` | `1` | Auto-fix missing parts by downloading/installing (alias: `--autoheal`). |
| `--autofill-missing-app=1/0` | `1` | Auto-fix missing app files (alias: `--autoheal-app`). |
| `--autofill-missing-db=1/0` | `1` | Auto-fix missing DB content (alias: `--autoheal-db`). |
| `--latest` | `false` | Use the newest backup when `--file` is not given (alias: `--file-latest`, `--file_latest`). |
| `--auto-select=true/false` | `false` | Auto-select newest backup when no TTY (alias: `--auto_select`). |

DB-only restore:

```bash
inm db restore --file=path --force --purge=true
```

DB restore switches (`inm db restore`):

| Switch | Default | Description |
| --- | --- | --- |
| `--file=path` | unset | Path to SQL file or bundle. |
| `--force` | `false` | Required (destructive). |
| `--purge=true/false` | `true` | Drop existing tables before import. |

DB create:

```bash
inm db create
```

DB create switches (`inm db create`):

| Switch | Default | Description |
| --- | --- | --- |
| `--db-host=host` | `DB_HOST` | Override DB host for creation. |
| `--db-port=port` | `DB_PORT` | Override DB port for creation. |
| `--db-name=name` | `DB_DATABASE` | Override DB name for creation. |
| `--db-user=user` | `DB_USERNAME` | Override DB user for creation. |
| `--db-pass=pass` | `DB_PASSWORD` | Override DB password for creation. |

DB purge (drop all tables/views, keep DB):

```bash
inm db purge --force
```

> [!WARNING]
> Destructive: removes all tables/views in the configured database. The database itself is kept and requires DROP privileges.

## Health checks

```bash
inm core health
```

Health switches (`inm core health`):

| Switch | Default | Description |
| --- | --- | --- |
| `--checks=TAG1,TAG2` | unset | Run only selected check groups. |
| `--check=TAG1,TAG2` | unset | Alias for `--checks`. |
| `--exclude=TAG1,TAG2` | unset | Run all checks except these groups. |
| `--fix-permissions` | `false` | Repair ownership where possible. |
| `--override-enforced-user` | `false` | Skip user switching for this run. |
| `--notify-test` | `false` | Send a test notification immediately. |
| `--notify-heartbeat` | `false` | Emit heartbeat notification based on results. |
| `--no-cli-clear` | `false` | Keep terminal output (skip clear + logo). |
| `--debug` | `false` | Verbose output. |
| `--dry-run` | `false` | Log only; skip changes where applicable. |

Filter tags:

```text
CLI,SYS,FS,ENVCLI,ENVAPP,CMD,WEB,PHP,EXT,WEBPHP,NET,MAIL,DB,APP,CRON,SNAPPDF
```

Exclude example:

```bash
inm core health --exclude=FS,CRON
```

> [!TIP]
> If you run `--fix-permissions` as root, add `--override-enforced-user` to avoid switching to the enforced user.

## Cron

```bash
inm core cron install
```

This installs artisan schedule + backup cron jobs (and heartbeat if selected).

Short form (same behavior):

```bash
inm cron install
```

Cron switches (`inm core cron install`):

| Switch | Default | Description |
| --- | --- | --- |
| `--user=name` | enforced user | User for cron entries. |
| `--jobs=artisan / backup / heartbeat / essential / both / all` | `both` | Which jobs to install. |
| `--mode=auto / system / crontab` | `auto` | Force cron install mode. |
| `--backup-time=HH:MM` | `03:24` | Backup cron schedule (24h). |
| `--heartbeat-time=HH:MM` | `06:00` | Heartbeat cron schedule (24h). |
| `--cron-file=path` | `/etc/cron.d/invoiceninja` | Target cron file (root mode only). |
| `--create-test-job` | `false` | Add a test job that touches `crontestfile` every minute. |

> [!TIP]
> `essential` (or legacy `both`) installs artisan + backup. `all` adds the heartbeat job.

Cron uninstall:

```bash
inm core cron uninstall [--mode=auto|system|crontab] [--cron-file=path]
```

Short form:

```bash
inm cron uninstall
```

Cron test job removal:

```bash
inm core cron uninstall --remove-test-job
```

> [!NOTE]
> Some systems use `${HOME}/cronfile` for user cron entries. If it exists, inm will use it as the base and keep it updated.

## Notification system (heartbeat)

Goal: send notifications for **non‑interactive** failures (e.g., scheduled backups, missing cron jobs, or a failing daily health check).

Config keys (set in `.inmanage/.env.inmanage`):

- `INM_NOTIFY_ENABLED=true|false` — master switch.
- `INM_NOTIFY_TARGETS=email,webhook` — comma list of targets.
- `INM_NOTIFY_EMAIL_TO=you@example.com` — comma‑separated recipients.
- `INM_NOTIFY_EMAIL_FROM=addr` / `INM_NOTIFY_EMAIL_FROM_NAME=name` — optional overrides.
- `INM_NOTIFY_LEVEL=ERR|WARN|INFO` — minimum severity to send.
- `INM_NOTIFY_NONINTERACTIVE_ONLY=true|false` — only send when no TTY is attached.
- `INM_NOTIFY_SMTP_TIMEOUT=10` — SMTP timeout (seconds).
- `INM_NOTIFY_HOOKS_ENABLED=true|false` — enable hook notifications.
- `INM_NOTIFY_HOOKS_FAILURE=true|false` — notify when hooks fail.
- `INM_NOTIFY_HOOKS_SUCCESS=true|false` — notify when hooks succeed.
- `INM_NOTIFY_HEARTBEAT_ENABLED=true|false` — enable daily health heartbeat.
- `INM_NOTIFY_HEARTBEAT_TIME=HH:MM` — cron schedule for the heartbeat.
- `INM_NOTIFY_HEARTBEAT_LEVEL=ERR|WARN|INFO|OK` — minimum severity for heartbeat.
- `INM_NOTIFY_HEARTBEAT_INCLUDE=TAG1,TAG2` — optional include filter.
- `INM_NOTIFY_HEARTBEAT_EXCLUDE=TAG1,TAG2` — optional exclude filter.
- `INM_NOTIFY_WEBHOOK_URL=https://...` — webhook target URL (https only).

Commands:

- `inm core health --notify-test` — send a test notification immediately.
- `inm core health --notify-heartbeat` — heartbeat run (used by cron).
- `inm core cron install --jobs=heartbeat` — install the daily heartbeat cron job.
- `inm core cron install --jobs=all` — artisan + backup + heartbeat.

Email settings are read from the app `.env` (`MAIL_*`).

> [!NOTE]
> For heartbeat alerts, set both `INM_NOTIFY_ENABLED=true` and `INM_NOTIFY_HEARTBEAT_ENABLED=true`.

### Adding notification transports

To add a new target, create a helper that defines:

- `notify_send_<name>` (optional low‑level sender)
- `notify_transport_<name>` (adapter used by the dispatcher)

Place it under `lib/helpers/notify_<name>.sh` and ensure it is sourced by `lib/services/notify.sh`.
Targets are activated by adding `<name>` to `INM_NOTIFY_TARGETS`.

## Environment helper

```bash
inm env show cli
inm env show app
inm env set app APP_URL https://example.test
```

If the target env file is not readable/writable, `inm env get/set/unset/show` will prompt to use sudo (or fail in non‑interactive mode).

## Cache and downloads

- Global cache: `${INM_CACHE_GLOBAL_DIRECTORY}` (default: `${HOME}/.inmanage/cache`)
- Local cache: `${INM_CACHE_LOCAL_DIRECTORY}` (default: `./.cache`)

If the global cache is not writable, inm falls back to local cache and may ask to fix permissions with sudo.

## Database client selection

MySQL and MariaDB are both supported. If both clients are installed and the DB is configured, you can pin one:

```bash
INM_DB_CLIENT=mysql
# or
INM_DB_CLIENT=mariadb
```

## Debugging

Version info:
- `inm version` (CLI)
- `inm self version` (same as above)
- `inm core versions` (Invoice Ninja versions: installed/latest/cached)

See the Global switches table for `--debug` and `--dry-run`.

## Sudo usage

Inmanage uses `sudo` only when needed (e.g., switching to the enforced user, fixing cache permissions, or system-wide install paths).

If `sudo` is not available:

- Run the CLI as the enforced user directly (e.g., `sudo -u www-data` is not possible, so login as that user).
- Use a user/project install mode instead of system mode.
- Point `INM_CACHE_GLOBAL_DIRECTORY` to a writable path or rely on the local cache (`./.cache`).
- Ensure the base directory and app directory are owned by the enforced user.

## FAQ

- **Use with existing installs?** Yes. Run a backup, then use `core update`.
- **Web updates okay?** Yes, but inm gives you versioned backups and rollback.
- **Docker?** Yes, with correct mounts and a real shell for the enforced user.
- **Failed install?** Retry or rollback to the previous version directory.
- **Config wrong/old?** Edit or delete `.inmanage/.env.inmanage` to regenerate.
- **SQL from backup?** `tar -xf *YYYYMMDD*.tar.gz --wildcards '*.sql' --strip-components=6`

## Troubleshooting (short)

- **Config missing**: run any command from the base directory and create `.inmanage/.env.inmanage` when prompted.
- **Permission errors**: ensure the enforced user matches your web server user, or use `--override-enforced-user` for a run.

## Docker notes

- Ensure the base directory and app directory are writable by the enforced user.
- Give the enforced user a real shell (e.g., `/bin/bash`) if it defaults to `nologin`.
- Install required CLI tools inside the container (mysql/mariadb client + dump, rsync, zip).
- Cron is often better handled by the host; otherwise use a cron-enabled container.
- inm updates use less RAM than web-based updates, which helps on small containers.
- One-command backups, updates, and restores reduce manual container exec steps.
- Provision files make setup repeatable across staging/production containers.
- Health checks give a quick system/app/DB overview without manual probing.

### Docker backups with backup_remote_job.sh

`backup_remote_job.sh` pulls backup bundles from a server to another machine. It standardizes rsync/scp, hooks, and file paths so off‑box backups stay repeatable.

Docker‑friendly flow:
- Write backups inside the container to a **mounted volume**.
- Run `backup_remote_job.sh` on the destination to pull the bundles.

Benefits over container snapshots:
- App‑level consistency (DB + files in a controlled order).
- Portability (restore outside Docker or into a fresh container).
- Clear rollback points (timestamped bundles).

Minimal steps:
1. Ensure `backup_remote_job.sh` is present in your install.
2. Point it at the mounted backup path.
3. Run it from the destination host.

Tip: set `REMOTE_PRE_HOOK` to `docker exec <container> inm core backup` so the backup is created right before the pull.

## libSaxon (XSLT2) for e‑invoicing

Invoice Ninja uses XSLT2 for e‑invoice schemas. That requires the Saxon PHP extension (`saxon.so`) to be loaded for both CLI and PHP‑FPM.

Quick checks:

```bash
php -m | grep -i saxon
php -r 'var_dump(extension_loaded("saxon"));'
```

> [!NOTE]
> - On shared hosting, enable the Saxon extension in cPanel if available.
> - On Docker images used by the project, it may already be installed.
> - On bare‑metal Linux, you typically install the shared library first, then compile/enable the PHP extension.

See the official installation instructions:
<https://invoiceninja.github.io/en/self-host-installation/#lib-saxon>
