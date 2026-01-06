# INmanage – Invoice Ninja CLI

INmanage (inm) – CLI for Invoice Ninja

**Backup. Update. Install. Done.**

INmanage is the CLI for self-hosted Invoice Ninja. Focus: **save time**, **less stress**, **certainty**, **convenience**. Installation takes 2–3 minutes and will save you many hours of manual work maintaining your Invoice Ninja instance.

> [!TIP]
> Docs:
> - Cheat sheet: [cheatsheet.md](./cheatsheet.md)
> - Full documentation: <https://github.com/DrDBanner/inmanage/blob/main/docs/index.md>
> - Containers/VMs onboarding: <https://github.com/DrDBanner/inmanage/blob/main/docs/index.md#containers--vms-onboarding>
> - Install CLI: <https://github.com/DrDBanner/inmanage/blob/main/docs/index.md#install-cli>
> - Health checks: <https://github.com/DrDBanner/inmanage/blob/main/docs/index.md#health-checks-inmanage>
> - Cron jobs: <https://github.com/DrDBanner/inmanage/blob/main/docs/index.md#cron-jobs-inmanage>

## Things You Need

| Requirement | Notes |
| --- | --- |
| Bash | Required shell. |
| Webserver | Apache or Nginx. |
| File owner user | User that owns the Invoice Ninja files (often the webserver user). |
| DB credentials | From `.env` or `.my.cnf`. |
| CLI tools | git, curl, tar, rsync, php, jq, composer, zip/unzip. |

## Install the CLI

Base directory = the folder that contains your Invoice Ninja app folder (or will contain it) (e.g. `/var/www/billing.yourdomain.com`), see [Directory Structure](#directory-structure).
Example: base directory `/var/www/billing.yourdomain.com`, app directory `/var/www/billing.yourdomain.com/invoiceninja`.

Quick Start (3 steps):

```bash
# 1) Install the CLI
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | bash

# 2) First run from your base directory (creates the CLI config file)
cd /path/to/your/invoiceninja_basedirectory
sudo -u www-data inm

# 3) Run a health check (verifies system/app/DB/cron readiness)
inm core health
```

> [!NOTE]
> Replace `www-data` with your webserver user if needed. See [First Run](#first-run).

Most common commands:

```bash
inm core health
inm core install --provision
inm core update
inm core backup
inm core restore --file=/path/to/bundle.tar.gz --force
```

### Install Options (system/user/project)

Use these if you need system or project installs.

#### Per user

```bash
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | bash
```

The installer auto-selects the install mode (system when run as root, otherwise user).

- System install: run with sudo; installs to `/usr/local/share/inmanage`, symlinks in `/usr/local/bin`.
- User install: default without sudo; installs to `~/.local/share/inmanage`, symlinks in `~/.local/bin`.
- Project install: run from your base directory; installs to `./.inmanage/cli`, symlinks in the project root.

#### Per project

```bash
cd /path/to/your/invoiceninja_basedirectory
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | bash -s -- --mode project
```

#### Per system

```bash
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | sudo bash
```

#### Per system with ownership/permissions (optional)

```bash
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | sudo bash -s -- --mode system --install-owner=root:vuser --install-perms=775:664
```
*Ownership/permissions may be required so your current user can read the installed CLI version and update it if needed.*



### First Run

Creates `.inmanage/.env.inmanage` and folders.

```bash
cd /path/to/your/invoiceninja_basedirectory
sudo -u www-data inm
```

If `sudo` isn't needed:

```bash
inm
```

> [!NOTE]
> * Run the script as a user who can read the `.env` file of your Invoice Ninja installation. Typically, this is the web server user, such as `www-data`, `httpd`, `web`, `apache`, or `nginx`. In shared hosting environments, it is often the logged-in user (e.g., `u439534522`).
> * `sudo -u <user> inm ...` runs the command as that OS user now. `--run-user <user>` is for install mode only (it sets who owns/should run the CLI after install).
> * Ensure you set the correct username in the script’s `.env.inmanage` file under `INM_ENFORCED_USER` and especially on the first run (otherwise you'll need to change permissions afterwards).
> * In restricted environments (e.g., shared hosting with GitHub rate limits), set the `INM_GH_API_CREDENTIALS` variable in `.env.inmanage` as `USERNAME:PASSWORD` or `token:x-oauth` if needed.

If the installer created symlinks (system/user/project), you can use `inm` (short) or `inmanage`. Otherwise run the CLI from its install path with `./inm` or `./inmanage`.

### Directory Structure

```text
/var/www/billing.yourdomain.com/            # Base directory
├── .inmanage/                              # The Project's CLI Configuration directory. (automatically created)
│   ├── .env.inmanage                       # CLI config file (auto-created)
│   └── cli/                                # Optional binaries folder if project wide installation
├── .cache/                                 # Optional. Local Project Cache.
├── .backup/                                # Backups go here.
├── invoiceninja/                           # The current/future Invoice Ninja app installation directory
│   └── public/                             # Document root (set this as your web server root folder)
```



## Recommended Invoice Ninja Install (Provisioned)

Go to your base directory and follow this Invoice Ninja installation procedure:

```bash
# 1. Check if your environment satisfies the dependencies
inm core health

# 2. Run installation wizard
inm core install

# 3. Select `provisioned` by pressing enter
[ENTER]

# 4. 
# edit .inmanage/.env.provision; 
# Then run the installer
inm core install --provision
```

## Core Commands (Examples)

```bash
inm core health
inm core install [--clean] [--provision] [--version=v]
inm core update [--version=v] [--force]
inm core update rollback last
inm core backup [--name=label] [--compress=tar.gz|zip|false]
inm core restore --file=path [--force] [--include-app=true|false]
```

## Help

```bash
inm -h
inm core health -h
inm version
inm core versions
```

## Extended Docs

> [!TIP]
> Docs:
> - Full documentation: <https://github.com/DrDBanner/inmanage/blob/main/docs/index.md>
> - Containers/VMs onboarding: <https://github.com/DrDBanner/inmanage/blob/main/docs/index.md#containers--vms-onboarding>

## What You Get (incl. safety notes)

Short list below; each item is explained in the extended docs.

- Fast CLI install (system, user, or project) with self‑update and uninstall.
- Guided install wizard (clean or provisioned), plus fully unattended provision flow.
- Safe updates with rollback directories (no silent deletes), optional DB backups, and lower RAM usage than GUI updates.
- Backups with checksums (SHA‑256) and restore (bundle or DB‑only).
- DB tooling (create/import/purge/db-only backup) with .my.cnf support and prompts.
- Provisioned installs are repeatable and auditable.
- Health checks for system, app, PHP, DB, filesystem, cron, network, and more.
- Snappdf/PDF readiness checks and setup helpers.
- Heartbeat notifications (email/webhook) for non‑interactive failures.
- Cron management (artisan scheduler, backup, heartbeat, test job).
- Hooks before/after install, update, and backup for custom automation.
- Environment helper (`inm env get/set`) for app and CLI config.
- CLI config/provision helpers (generate config, provision file).
- Permission enforcement and fix‑permissions helper for shared hosting.
- Docker/VM onboarding, including sidecar guidance and cron placement.
- Ops/history log for auditability of CLI actions.
- Cache management for downloads and release pruning.
- Version discovery for installed/latest/cached releases.
- Cache-only release fetch (`core get app`) for preloading versions.
