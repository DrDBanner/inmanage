# INMANAGE – Invoice Ninja CLI

**Backup. Update. Install. Done.**

inmanage steuert deine self-hosted Invoice Ninja Installation per CLI: installieren, updaten, sichern, wiederherstellen, Cron setzen – alles skriptbar. Ruf es als `inmanage <context> <action> [--options]` auf (Legacy `./inmanage.sh` geht auch).

## Highlights

- Installation (Wizard oder Provision) getrennt von der GUI.
- Backups für DB und Files (Storage/Uploads) mit Aufbewahrung & Restore.
- Updates mit Rollback (alte Versionen werden gesichert).
- Snappdf-Setup inklusive.
- Cron-Installer für Artisan/Backups.
- Debug-Logging mit `--debug`, Dry-Run mit `--dry-run`.
- Backups mit Checksums (SHA-256) für Integrität.


---

## Quick Setup

Three steps: pick a mode, install, then run the wizard in your Invoice Ninja base directory.

1) Choose a mode (see below).  
2) Run the installer command for that mode.  
3) `cd` into your Invoice Ninja base directory, then run: `inmanage core install` (or `--provision`). In project mode use `./inmanage.sh core install`.

### System mode (recommended, sudo)
Use when you want `inmanage` globally available; good for servers and team access.
```
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | sudo bash
```
Installs to `/usr/local/share/inmanage`, symlinks `/usr/local/bin/{inmanage,inm}`. Result: callable everywhere; config stays with your Invoice Ninja base.

### User mode (no sudo)
Use on shared hosts or when you can’t escalate; keeps everything in your home.
```
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | MODE=user bash
```
Installs to `~/.inmanage_app`, symlinks `~/.local/bin/{inmanage,inm}`. Result: callable for your user; isolated from system.

### Project mode (keep it with your repo)
Use when you want the CLI alongside a project checkout; ideal for per-project versioning.
```
git clone https://github.com/DrDBanner/inmanage.git .inmanage
cd .inmanage
MODE=project ./install_inmanage.sh
```
CLI goes to `../.inmanage_app`, config stays in `../.inmanage/`, local symlinks created (`./inmanage`, `./inm`).

After install (all modes):  
```
cd /path/to/your/invoiceninja/base
inmanage core install          # or: inmanage core install --provision
```

Where things live & how to update:
- System: `/usr/local/share/inmanage` + symlinks `/usr/local/bin/{inmanage,inm}`.
- User: `~/.inmanage_app` + symlinks `~/.local/bin/{inmanage,inm}`.
- Project: `.inmanage_app` + config `.inmanage/` in the project tree.
Default config: `.inmanage/.env.inmanage`. Do not install inside the `invoiceninja/` app folder.
Update by rerunning the installer for your mode; it will git-pull and refresh symlinks. Use `--dry-run` on commands to see intended actions without changes.

---

## Commands (new structure)

```bash
./inmanage.sh <context> <action> [--options]
```

| Context | Action / Example                                          | Description                                                       |
|---------|-----------------------------------------------------------|-------------------------------------------------------------------|
| core    | `install [--clean] [--provision] [--version=v]`           | Install Invoice Ninja (provision file if present, flags optional) |
|         | `update [--version=v] [--force]`                          | Update to specific/latest version                                 |
|         | `backup [--compress=tar.gz|zip|false] [--name=...] [--include-app=true|false] [--extra-paths=a,b]` | Full backup (db+files; optional app and extra paths) |
|         | `restore --file=path [--force] [--include-app=true|false] [--target=...]` | Restore from bundle (pick latest if omitted)                      |
|         | `health` \| `info`                                        | Preflight/health check                                            |
|         | `version`                                                 | Show installed/latest/cached version                              |
|         | `prune` \| `prune-versions` \| `prune-backups`            | Remove old versions/backups/cache                                 |
|         | `clear-cache`                                             | Clear app cache via artisan                                       |
| db      | `backup [--compress=tar.gz|zip|false] [--name=...]`       | DB-only backup                                                    |
|         | `restore --file=path [--force] [--purge=true]`            | Import/restore database                                           |
|         | `create`                                                  | Create database and user                                          |
|         | `prune`                                                   | Prune old DB backups (alias to core prune-backups)                |
| files   | `backup [--compress=tar.gz|zip|false] [--name=...]`       | Files-only backup (storage/uploads)                               |
|         | `prune`                                                   | Cleanup old file backups                                          |
| cron    | `install`                                                 | Install cronjobs                                                  |
| self    | `install`                                                 | Install this CLI (global/local/project)                           |
| env     | `set|get|unset|show`                                      | Manage application .env entries                                   |
| provision | `spawn`                                                 | Create provision file for unattended install                      |

Legacy single-word commands (`install`, `clean_install`, `backup`, `update`, etc.) still work but are no longer documented; prefer the new context/action format. All commands support `-h` for usage.

---

## Configuration

Generated on first run as `.inmanage/.env.inmanage`. Example:

```bash
INM_BASE_DIRECTORY="/var/www"
INM_INSTALLATION_DIRECTORY="./invoiceninja"
INM_ENV_FILE="./invoiceninja/.env"
INM_BACKUP_DIRECTORY="./_in_backups"
INM_ENFORCED_USER="www-data"
INM_PHP_EXECUTABLE="/usr/bin/php"
INM_ARTISAN_STRING="/usr/bin/php ./invoiceninja/artisan"
INM_KEEP_BACKUPS="2"
```

---

## Invoice Ninja Installation Wizard - CLI

```bash
inmanage core install                  # default install
inmanage core install --provision      # use .inmanage/.env.provision + seed defaults
inmanage core install --clean          # force fresh deploy (legacy clean_install)
```

What happens:

- Generates/uses `.inmanage/.env.inmanage` for settings (keeps config outside the app).
- Downloads and installs latest (or `--version`) Invoice Ninja.
- Creates DB/user (if configured), runs setup & migrations.
- Prompts for cron install & backup (or use `cron install` separately).

Use `.env.provision` for prefilled config. Fields like `DB_ELEVATED_USERNAME` are removed after successful setup.

---

## Cron Setup

```bash
./inmanage.sh cron install -h
```

Manual alternative:

**cron.d style:**

```bash
echo '* * * * * www-data /usr/bin/php /path/to/artisan schedule:run >> /dev/null 2>&1' | sudo tee /etc/cron.d/invoiceninja
```

**crontab style:**

```bash
* * * * * php /path/to/artisan schedule:run >> /dev/null 2>&1
```

Backup cron:

```bash
0 2 * * * www-data /path/to/inmanage.sh core backup >> /dev/null 2>&1
```

---

## Backup & Restore

- Create a full bundle (db + storage + uploads; optional app and extra paths):
  ```bash
  inmanage core backup --name=pre_migration --compress=tar.gz --include-app=true --extra-paths=custom1,custom2
  ```
- Restore (picks latest bundle if `--file` is omitted):
  ```bash
  inmanage core restore --force                   # pick latest
  inmanage core restore --file=./_in_backups/<bundle>.tar.gz --target=/var/www/invoiceninja
  ```
  Use `--include-app=false` to restore only DB/storage/uploads. `--force` overwrites an existing app dir.

---

## Rollback

```bash
mv invoiceninja invoiceninja_broken
mv invoiceninja_20250720_225551 invoiceninja
```

---

## Extract SQL from Backup

```bash
tar -xf InvoiceNinja_*.tar.gz --wildcards '*.sql' --strip-components=6
```

---

## FAQ (short)

- **Use with existing installs?** Yes
- **Deletes anything?** No – it moves or backs up
- **GUI updates okay?** Yes
- **Docker?** Yes, with correct shell + mounts
- **Failed install?** Retry or rollback
- **Custom env?** Edit or delete `.env.inmanage` to regenerate

## Register Global Command - Example

Not needed anymore: symlinks `inmanage`/`inm` are created by the installer (system/user/project). Call `inmanage …` directly.

## Update the Script

Update via sudo:

```bash
cd .inmanage && sudo -u www-data git pull
```

Or:

```bash
cd .inmanage && git pull
```

## Remote Backup

Naturally, you may want to store your backups on your local machine or on a remote backup server.

**Solution:**  
Run `inmanage core backup --create-backup-script [--script_path=/target/path.sh] [--force]`

- Creates a `backup_remote_job.sh` template (or your chosen path), marked executable.
- Includes inline instructions for SSH keys, rsync/scp usage, pre/post hooks.
- Example pre-hook: set `REMOTE_PRE_HOOK="inmanage core backup --db=true --storage=false --uploads=false --bundle=false --name=remote_db_only"` on the remote and include `/path/to/.inmanage/_backups/` in REMOTE_PATHS so the DB dump is pulled.
- Requires rsync and SSH key access from the pull side; existing files are only overwritten with `--force`.

This helper is designed to be run **from the destination machine** to pull backups from the Ninja server without opening extra ports.

**Endless possibilities:**  
Back up to your NAS, a remote server, or even your local machine.  

The script is designed to be run **from the destination machine**, so you can easily pull backups from your Invoice Ninja server — even to your desktop — without fiddling around with router ports or VPN settings.


## FAQ

### Can I use this script if Invoice Ninja is already installed manually?

Yes. Install the script as described, run a backup, then run a forced update. Nothing is deleted or overwritten unexpectedly.

### Can I use this script if my installation is broken or has permission issues?

Yes. The script will move your old installation, pull a fresh version, and reapply the configuration. If needed, it will attempt to fix permission issues.

### Can I continue using the Invoice Ninja GUI for updates?

Yes. The script works independently. However, the script allows you to perform versioned backups before any update.

### Can I use this script for automated backups?

Yes. Add a cronjob `./inmanage.sh install_cronjob -h` to automate backups.

### How do I install the Invoice Ninja artisan scheduler cronjob?

Yes. Add a cronjob `./inmanage.sh install_cronjob -h` to do that.

### What if I made a mistake during the installation wizard?

Edit or delete `.inmanage/.env.inmanage`. The script will regenerate it's if missing.

### What about Docker and write permissions?

Ensure the script runs inside the correct container with appropriate mount settings. Grant `www-data` a shell and file write permissions.

### Does the script delete my old setup when I run a clean install?

No. It renames the old folder before creating a new one. Manual confirmation is required.

### How do I extract just the database SQL file from a backup?

Go to your backup directory and run:

```bash
tar -xf *YYYYMMDD*.tar.gz --wildcards '*.sql' --strip-components=6
```

Replace `YYYYMMDD` with the desired date.

### What about non-standard .env files?

The `.env.provision` file is based on a standard `.env`, but includes elevated DB user credentials. These fields are removed after provisioning.

## Docker Notes

Ensure proper container and mount access. Example setup:

```bash
apt update && apt install git sudo
cd /var/www && usermod -s /bin/bash www-data && chown root:www-data . && chmod 775 .
```

Clone and run:

```bash
runuser www-data -c "git clone https://github.com/DrDBanner/inmanage.git .inmanage && .inmanage/inmanage.sh"
```

Create `.my.cnf` (optional):

```bash
echo -e "[client]
user=ninja
password=ninja
database=ninja
host=localhost" > /var/www/.my.cnf
chown www-data:www-data /var/www/.my.cnf
chmod 600 /var/www/.my.cnf
```

### Docker Limitations

#### User shell and permissions

The `www-data` user typically lacks a login shell. This must be explicitly set (`usermod -s /bin/bash www-data`) for the script to function correctly.

#### Backup location

Recommended backup path in Docker: `./html/storage/app/public/_in_backups`, which is within persisted volume scope.
