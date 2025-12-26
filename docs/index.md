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

The installer asks for an install mode and creates symlinks (`inmanage`, `inm`) if possible.

## First run

Run any command from the base directory. If no CLI config exists, you will be prompted to create it.

```bash
inmanage core health
```

## Install Invoice Ninja

### Provisioned install (recommended)

Repeatable and unattended. Best for staging/production.

1) Generate a provision file:

```bash
inmanage core provision spawn
```

`spawn` creates a ready-to-edit `.env.provision` from the bundled `.env.example` (or app `.env` if present).

2) Edit `.inmanage/.env.provision` (DB creds, APP_URL, etc.)
   - `DB_ELEVATED_USERNAME` and `DB_ELEVATED_PASSWORD` are only used to create the DB/user if needed and are removed after success.

3) Install:

```bash
inmanage core install --provision
```

Notes:
- A clean `.env.example` is bundled and used to seed `.env.provision`.
- `DB_ELEVATED_USERNAME` / `DB_ELEVATED_PASSWORD` are required only if the script should create the DB/user; otherwise the DB must already exist and match the `DB_*` values.
- Elevated credentials are removed from `.env.provision` after a successful provision.

What happens on a provisioned install:
- Create the database and user (when elevated creds are provided).
- Download and install the latest Invoice Ninja release.
- Move `.env.provision` to app `.env`.
- Generate app key, run migrations/seed, warm cache.
- Create an admin user.
- Suggest cronjobs and prompt for a first backup.

Mandatory settings to review (common):

- `APP_URL`
- `DB_PASSWORD`
- `DB_ELEVATED_USERNAME`
- `DB_ELEVATED_PASSWORD`
- `PDF_GENERATOR=snappdf` (if you use Snappdf)
- Mail settings: `MAIL_HOST`, `MAIL_PORT`, `MAIL_USERNAME`, `MAIL_PASSWORD`, `MAIL_ENCRYPTION`, `MAIL_FROM_ADDRESS`, `MAIL_FROM_NAME`

Optional: set any other Invoice Ninja `.env` keys you need. Official env reference:
https://invoiceninja.github.io/en/self-host-installation/#configure-environment

### Wizard install

Use this only if you want the interactive web setup:

```bash
inmanage core install
```

The wizard installs the app but leaves database setup to the web UI.

### Clean/forced install

```bash
inmanage core install --clean
```

This renames the existing app directory before deploying a fresh version.

## Updates

```bash
inmanage core update
```

- Updates keep the previous version for rollback.
- Use `--version=v` to install a specific version.
- Uses less RAM than web-based updates, especially on small servers.

Rollback example:

```bash
mv invoiceninja invoiceninja_broken
mv invoiceninja_YYYYMMDD_HHMMSS invoiceninja
```

## Backups

Full bundle (db + storage + uploads; optional app + extras):

```bash
inmanage core backup --name=pre_migration --compress=tar.gz --include-app=true --extra-paths=custom1,custom2
```

DB-only and files-only backups:

```bash
inmanage db backup --name=label
inmanage files backup --name=label
```

## Restore

```bash
inmanage core restore --file=path --force
```

- Use `--include-app=false` to restore only DB/storage/uploads.
- DB-only restore:

```bash
inmanage db restore --file=path --force --purge=true
```

## Health checks

```bash
inmanage core health
```

Filter checks with `--checks=TAG1,TAG2`. Tags:

```
CLI,SYS,FS,ENVCLI,ENVAPP,CMD,WEB,PHP,EXT,WEBPHP,NET,DB,APP,CRON,SNAPPDF
```

Other useful flags:

- `--fix-permissions` (repairs permissions where possible)
- `--override-enforced-user` (skip user switch for this run)
- `--no-cli-clear` or `INM_NO_CLI_CLEAR=1` (keep terminal output)

## Cron

```bash
inmanage core cron install
```

This installs artisan schedule + backup cron jobs.

## Environment helper

```bash
inmanage env show cli
inmanage env show app
inmanage env set app APP_URL https://example.test
```

## Cache and downloads

- Global cache: `${INM_CACHE_GLOBAL_DIRECTORY}` (default: `${HOME}/.inmanage/cache`)
- Local cache: `${INM_CACHE_LOCAL_DIRECTORY}` (default: `./.cache`)

If the global cache is not writable, inmanage falls back to local cache and may ask to fix permissions with sudo.

## Database client selection

MySQL and MariaDB are both supported. If both clients are installed and the DB is configured, you can pin one:

```bash
INM_DB_CLIENT=mysql
# or
INM_DB_CLIENT=mariadb
```

## Debugging

- `--debug` for verbose logs
- `--dry-run` to show intended actions without executing them

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
- **Web updates okay?** Yes, but inmanage gives you versioned backups and rollback.
- **Docker?** Yes, with correct mounts and a real shell for the enforced user.
- **Failed install?** Retry or rollback to the previous version directory.
- **Config wrong/old?** Edit or delete `.inmanage/.env.inmanage` to regenerate.
- **Clean install deletes my app?** No, it renames the old app before deploying.
- **SQL from backup?** `tar -xf *YYYYMMDD*.tar.gz --wildcards '*.sql' --strip-components=6`
- **Non-standard .env?** `.env.provision` is seeded from `.env.example`; elevated creds are removed after provision. You can add any valid Invoice Ninja `.env` keys.

## Troubleshooting (short)

- **Config missing**: run any command from the base directory and create `.inmanage/.env.inmanage` when prompted.
- **Permission errors**: ensure the enforced user matches your web server user, or use `--override-enforced-user` for a run.
- **DB ambiguity**: set `INM_DB_CLIENT` explicitly.

## Docker notes

- Ensure the base directory and app directory are writable by the enforced user.
- Give the enforced user a real shell (e.g., `/bin/bash`) if it defaults to `nologin`.
- Install required CLI tools inside the container (mysql/mariadb client + dump, rsync, zip).
- Cron is often better handled by the host; otherwise use a cron-enabled container.
- inmanage updates use less RAM than web-based updates, which helps on small containers.
- One-command backups, updates, and restores reduce manual container exec steps.
- Provision files make setup repeatable across staging/production containers.
- Health checks give a quick system/app/DB overview without manual probing.

### Docker backups with backup_remote_job.sh

`backup_remote_job.sh` is a helper script generated by inmanage to pull backup bundles from a server to another machine (local or remote). It standardizes rsync/scp, optional hooks, and file paths so you get consistent, repeatable off-box backups.

In Docker, this is especially useful because it avoids relying on container snapshots and gives you **app‑level** bundles (DB + files) that can be restored anywhere.

What it does:

- Triggers (or waits for) a backup on the source.
- Copies the bundle(s) to your destination machine.
- Preserves clear, timestamped rollback points.

How it works with Docker:

- Write backups inside the container into a **mounted volume** so the host can access them.
- Use `backup_remote_job.sh` on the destination to pull those bundles.

Why this is better than container snapshots:

- **App-level consistency**: inmanage bundles DB + files in a controlled order.
- **Portability**: one bundle restores outside Docker or into a fresh container.
- **Clear rollback**: you know exactly which backup was created and when.

How to run it:

1) Generate the helper script: `inmanage core backup --create-backup-script`.
2) Configure it to point at your mounted backup path.
3) Run it from the destination machine to pull the bundles automatically.

Tip: set `REMOTE_PRE_HOOK` to `docker exec <container> inmanage core backup` so the backup is created just before the pull.
