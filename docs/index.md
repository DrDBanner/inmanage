# INMANAGE Documentation

Inmanage is the CLI for self-hosted Invoice Ninja. It is built for **convenience**, **certainty**, and **low stress**. Everything is designed to be repeatable and safe.

## Mental model

- **Base directory**: the folder that contains your Invoice Ninja app folder.
- **Install directory**: the app folder itself (default: `./invoiceninja`).
- **CLI config** lives in `.inmanage/` next to your app, not inside it.

## Files you should know

- `.inmanage/.env.inmanage` — CLI config (generated on first run)
- `.inmanage/.env.provision` — provisioned install config (unattended)
- `<install>/.env` — Invoice Ninja app config

## Install the CLI

```bash
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | bash
```

The installer asks for an install mode and creates symlinks (`inm`, `inmanage`) if possible.
If you choose project mode, run the installer from your base directory.
System mode requires sudo; the installer can rerun with sudo if selected.

Installer options (`install_inmanage.sh`):

| Switch | Default | Description |
| --- | --- | --- |
| `--mode system / user / project` | `system` | Install mode (system requires sudo). |
| `--target DIR` | mode default | Install directory. |
| `--symlink-dir DIR` | mode default | Where to place `inm`/`inmanage` symlinks. |
| `--branch BRANCH` | fetched branch | Git branch to install. |
| `--source PATH` | unset | Use an existing checkout (rsync with `--delete`). |
| `-h` / `--help` | | Show installer help. |

Installer env vars:
- `BRANCH` (branch to install)
- `INSTALLER_BRANCH` (default branch when not set; usually matches the fetched script)
- `MODE` / `TARGET_DIR` / `SYMLINK_DIR` / `SOURCE_DIR` (same as switches)

Use `--source` when you already have a local checkout (e.g., mounted dev workspace or offline/air‑gapped install) and want to sync it into the install target.

### Install from a different branch

Install from `development`:

```bash
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/development/install_inmanage.sh | sudo BRANCH=development bash
```

You can also pass the branch flag explicitly:

```bash
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/development/install_inmanage.sh | sudo bash -s -- --branch development
```

### Switch branches later

If you installed from a git checkout, re-run the installer with a new branch:

```bash
sudo BRANCH=development bash install_inmanage.sh --branch development
```

Manual git switch (system install path shown):

```bash
cd /usr/local/share/inmanage
git fetch origin
git checkout development
git pull --ff-only
```

Note: `inm self update` only pulls the current branch; it does not switch branches.

## First run

Run any command from the base directory. If no CLI config exists, you will be prompted to create it.

```bash
inm core health
```

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

## libSaxon (XSLT2) for e‑invoicing

Invoice Ninja uses XSLT2 for e‑invoice schemas. That requires the Saxon PHP extension (`saxon.so`) to be loaded for both CLI and PHP‑FPM.

Quick checks:

```bash
php -m | grep -i saxon
php -r 'var_dump(extension_loaded("saxon"));'
```

Notes:
- On shared hosting, enable the Saxon extension in cPanel if available.
- On Docker images used by the project, it may already be installed.
- On bare‑metal Linux, you typically install the shared library first, then compile/enable the PHP extension.

See the official installation instructions:
<https://invoiceninja.github.io/en/self-host-installation/#lib-saxon>

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

1. Generate a provision file:
   ```bash
   inm core provision spawn
   ```
   `spawn` creates a ready-to-edit `.env.provision` from the bundled `.env.example` (or app `.env` if present).
2. Edit `.inmanage/.env.provision` (DB creds, APP_URL, etc.)
   - `DB_ELEVATED_USERNAME` and `DB_ELEVATED_PASSWORD` are only used to create the DB/user if needed and are removed after success.
3. Install:
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
| `--cron-jobs=scheduler / backup / both` | `both` | Which cron jobs to install during setup. |
| `--no-backup-cron` | `false` | Skip the backup cron job during setup. |
| `--backup-time=HH:MM` | `03:24` | Backup cron schedule (24h). |
| `--bypass-check-sha` | `false` | Skip release digest verification (not recommended). |
| `--version=v` | latest | Reserved: install currently uses latest release. |

Provision spawn switches (`inm core provision spawn`):

| Switch | Default | Description |
| --- | --- | --- |
| `--provision-file=path` | `.inmanage/.env.provision` | Where to write the provision file. |
| `--backup-file=path` | unset | Use a specific migration backup after install. |
| `--latest-backup` | `false` | Use the latest backup after install. |
| `--force` | `false` | Overwrite an existing provision file. |

Notes:
- A clean `.env.example` is bundled and used to seed `.env.provision`.
- `DB_ELEVATED_USERNAME` / `DB_ELEVATED_PASSWORD` are required only if the script should create the DB/user; otherwise the DB must already exist and match the `DB_*` values.
- Elevated credentials are removed from `.env.provision` after a successful provision.
- Migration restore can also be driven by `INM_MIGRATION_BACKUP` in `.env.provision` or `.env.inmanage` (set to `LATEST` or a backup path).

What happens on a provisioned install:
- Create the database and user (when elevated creds are provided).
- Download and install the latest Invoice Ninja release.
- Move `.env.provision` to app `.env`.
- Generate app key, run migrations/seed, warm cache.
- Create an admin user.
- Install cronjobs when possible (unless `--no-cron-install` or `--no-backup-cron`).
- If `INM_MIGRATION_BACKUP` is set, restore that backup after deploy (or continue fresh if not found).

Migration flow (provisioned install):

1. Create a migration backup on the source host:
   ```bash
   inm core backup --name=migration --compress=tar.gz --include-app=true
   ```
   Optionally write target-ready values into the backup `.env`:
   ```bash
   inm core backup --create-migration-export
   ```
2. On the target host, point provision to the backup:
   - `inm core provision spawn --backup-file=/path/to/backup.tar.gz`
   - or `inm core provision spawn --latest-backup`
   - or set `INM_MIGRATION_BACKUP=LATEST` (or a path) in `.env.provision` / `.env.inmanage`

### Install flow (under the hood)

Provisioned install (high‑level):

- Resolve base/app paths and load CLI/app config.
- Optional hooks: `pre-install`.
- Archive existing app directory if present.
- Download Invoice Ninja release and unpack into a temp directory.
- Place `.env` from `.env.provision`, remove the inm header block.
- Deploy the new app into the install path.
- Run artisan tasks: `key:generate`, `optimize`, `up`, `ninja:translations`, snappdf setup.
- Pre‑provision DB backup if tables exist (unless `--no-backup`).
- Create DB/user if needed (DB_ELEVATED_*), then `migrate:fresh --seed`.
- Language seeder + create admin user.
- Optional cron install (configurable via `--cron-mode`, `--cron-jobs`, `--backup-time`).
- Optional hooks: `post-install`.
- Final cache cleanup: `config:clear` + `cache:clear`.

Clean install (high‑level):

- Resolve base/app paths and load CLI/app config.
- Optional hooks: `pre-install`.
- Archive existing app directory if present.
- Download Invoice Ninja release and unpack into a temp directory.
- Deploy the new app into the install path.
- Place a default, unconfigured `.env` for the web wizard to fill in.
- Run artisan tasks: `key:generate`, `optimize`, `up`, `ninja:translations`, snappdf setup.
- Optional cron install (scheduler only by default).
- Optional hooks: `post-install`.
- Final cache cleanup: `config:clear` + `cache:clear`.

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

The wizard installs the app and drops a default `.env`. You must complete the web setup to write DB/app values, then manually review `.env` for settings the GUI doesn’t cover.

### Clean/forced install

```bash
inm core install --clean
```

This renames the existing app directory before deploying a fresh version.

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

Rollback:

```bash
inm update rollback last
inm update rollback invoiceninja_rollback_YYYYMMDD_HHMMSS
```

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

## Health checks

```bash
inm core health
```

Health switches (`inm core health`):

| Switch | Default | Description |
| --- | --- | --- |
| `--checks=TAG1,TAG2` | unset | Run only selected check groups. |
| `--check=TAG1,TAG2` | unset | Alias for `--checks`. |
| `--fix-permissions` | `false` | Repair ownership where possible. |
| `--override-enforced-user` | `false` | Skip user switching for this run. |
| `--no-cli-clear` | `false` | Keep terminal output (skip clear + logo). |
| `--debug` | `false` | Verbose output. |
| `--dry-run` | `false` | Log only; skip changes where applicable. |

Filter tags:

```text
CLI,SYS,FS,ENVCLI,ENVAPP,CMD,WEB,PHP,EXT,WEBPHP,NET,MAIL,DB,APP,CRON,SNAPPDF
```

## Cron

```bash
inm core cron install
```

This installs artisan schedule + backup cron jobs.

Short form (same behavior):

```bash
inm cron install
```

Cron switches (`inm core cron install`):

| Switch | Default | Description |
| --- | --- | --- |
| `--user=name` | enforced user | User for cron entries. |
| `--jobs=scheduler / backup / both` | `scheduler` | Which jobs to install. |
| `--mode=auto / system / crontab` | `auto` | Force cron install mode. |
| `--backup-time=HH:MM` | `03:24` | Backup cron schedule (24h). |
| `--cron-file=path` | `/etc/cron.d/invoiceninja` | Target cron file (root mode only). |

Cron uninstall:

```bash
inm core cron uninstall [--mode=auto|system|crontab] [--cron-file=path]
```

Short form:

```bash
inm cron uninstall
```

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
- **Deletes anything?** No silent deletes; old versions are moved aside.
- **Web updates okay?** Yes, but inm gives you versioned backups and rollback.
- **Docker?** Yes, with correct mounts and a real shell for the enforced user.
- **Failed install?** Retry or rollback to the previous version directory.
- **Config wrong/old?** Edit or delete `.inmanage/.env.inmanage` to regenerate.
- **Clean install deletes my app?** No, it renames the old app before deploying.
- **SQL from backup?** `tar -xf *YYYYMMDD*.tar.gz --wildcards '*.sql' --strip-components=6`
- **Non-standard .env?** `.env.provision` is seeded from `.env.example`; elevated creds are removed after provision. You can add any valid Invoice Ninja `.env` keys.
- **Provisioned install over existing app?** It archives the current app first, then installs fresh. DB changes are destructive unless you use `--no-backup` (not recommended). Always keep the generated pre‑provision backup.

## Troubleshooting (short)

- **Config missing**: run any command from the base directory and create `.inmanage/.env.inmanage` when prompted.
- **Permission errors**: ensure the enforced user matches your web server user, or use `--override-enforced-user` for a run.
- **DB ambiguity**: set `INM_DB_CLIENT` explicitly.
- **Health overview**: run `inm core health` (or `inm core health --checks=CRON,DB,WEB`) for a quick scan.

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

`backup_remote_job.sh` is a helper script generated by inm to pull backup bundles from a server to another machine (local or remote). It standardizes rsync/scp, optional hooks, and file paths so you get consistent, repeatable off-box backups.

In Docker, this is especially useful because it avoids relying on container snapshots and gives you **app‑level** bundles (DB + files) that can be restored anywhere.

What it does:

- Triggers (or waits for) a backup on the source.
- Copies the bundle(s) to your destination machine.
- Preserves clear, timestamped rollback points.

How it works with Docker:

- Write backups inside the container into a **mounted volume** so the host can access them.
- Use `backup_remote_job.sh` on the destination to pull those bundles.

Why this is better than container snapshots:

- **App-level consistency**: inm bundles DB + files in a controlled order.
- **Portability**: one bundle restores outside Docker or into a fresh container.
- **Clear rollback**: you know exactly which backup was created and when.

How to run it:

1) Use `backup_remote_job.sh` if it is available in your installation.
2) Configure it to point at your mounted backup path.
3) Run it from the destination machine to pull the bundles automatically.

Tip: set `REMOTE_PRE_HOOK` to `docker exec <container> inm core backup` so the backup is created just before the pull.
