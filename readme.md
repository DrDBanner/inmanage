# INMANAGE – Invoice Ninja CLI

**Backup. Update. Install. Done.**

Manage your self-hosted Invoice Ninja via CLI: validate environment, install, update, backup, restore, set cron.

Full documentation: see `docs/index.md` (install, config, automation, troubleshooting).

## Highlights

- Install (provisioned/unattended recommended; bare install leaves GUI setup) separate from the GUI.
- Backups for DB and files (storage/uploads) with retention & restore.
- Updates with rollback (old versions kept).
- Snappdf setup included.
- Cron installer for artisan/backups.
- Debug logging with `--debug`, dry-run with `--dry-run`.
- Backups with checksums (SHA-256) for integrity.

---

## Setup

At a glance (3 steps):

1) Install the CLI (mode prompt inside the installer)
2) Go to your Invoice Ninja base directory
3) Run Invoice Ninja App installer

Step 1 — Install the CLI (prompts for mode; asks for sudo only if you pick system)

```bash
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | bash
```

Result: CLI installed per chosen mode (system/user/project), symlinks created (`inmanage`, `inm`).

Step 2 — Go to your Invoice Ninja base directory

```bash
cd /path/to/your/invoiceninja/base
```

Step 3 — Install Invoice Ninja

```bash
inmanage core install
```

- Prompts for install type: **provisioned (recommended)** vs **clean GUI setup**.  
- If provisioned: you'll be offered to create/edit `.inmanage/.env.provision`, then it runs unattended.  
- If clean: a vanilla app is deployed; finish setup in the browser. You can also drop in an existing `.env` and a pre-imported database to reuse prior data.

Direct switches (skip prompts):

- Force provisioned: `inmanage core install --provision`
- Pick mode upfront: `--install-mode=system|user|project`
- Point to provision file: `--provision-env=.inmanage/.env.provision`

Where things live & updates:

| Mode    | CLI path                     | Symlinks                   | Config location          |
|---------|------------------------------|----------------------------|--------------------------|
| System  | `/usr/local/share/inmanage`  | `/usr/local/bin/{inmanage,inm}` | In your Ninja base: `.inmanage/` |
| User    | `~/.inmanage_app`            | `~/.local/bin/{inmanage,inm}`   | In your Ninja base: `.inmanage/` |
| Project | `../.inmanage_app`           | Local: `./inmanage`, `./inm`    | `../.inmanage/`          |

Default config: `.inmanage/.env.inmanage`. Do not install inside the `invoiceninja/` app folder.  
Update the CLI with `inmanage self update` (git checkout) or rerun the installer for your mode. Use `--dry-run` to see intended actions without changes.

---

## Commands

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
|         | `update`                                                  | Update this CLI (git pull if checkout)                            |
|         | `switch-mode`                                             | Reinstall CLI in another mode (optional cleanup)                  |
|         | `uninstall`                                               | Remove CLI symlinks; optional delete of install dir               |
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
inmanage cron install -h
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
0 2 * * * www-data /usr/local/bin/inmanage core backup >> /dev/null 2>&1
```

---

## Provisioned (unattended) install

1) Generate a template from your current config: `inmanage core provision spawn` (or `inm core provision spawn`). This writes `.inmanage/.env.provision`.
2) Edit `.inmanage/.env.provision` for the target host (DB creds, APP_URL, etc.). If you copy an existing config, keep mandatory keys like `INM_ENFORCED_USER`, `INM_ENFORCED_SHELL`, `INM_BASE_DIRECTORY`, `INM_INSTALLATION_DIRECTORY`, `INM_ENV_FILE`, and backup/cache paths intact.
3) From the Invoice Ninja base: `inmanage core install --provision`.
4) Optional: `inmanage core health` to verify.

Why provisioned is recommended vs GUI:

- Repeatable: reuse the same provision file for staging/production; no manual clicks.
- Auditable: values live in `.inmanage/.env.provision`, so changes are trackable.
- Automation-friendly: no prompts; safe for CI, recovery, and rollbacks.
- Safer layout: config stays outside the app tree, so app updates won’t overwrite it.

## Updating Invoice Ninja & CLI

- App update: `inmanage core update` (safe move/copy, keeps a backup directory).
- CLI update: `inmanage self update` (git checkout) or rerun the installer for your mode.
- Snappdf is installed/tested only if `PDF_GENERATOR=snappdf` in your app `.env`.

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

  Use `--include-app=false` to restore only DB/storage/uploads. `--force` will replace an existing app dir (backup first; we prefer renaming/move-over).

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

Recommended: use the CLI self-update (respects your install mode):

```bash
inmanage self update
```

Fallback (git checkout installs):

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

### Can I use this if Ninja is already installed manually?
Yes. Install inmanage, run a backup, dann `inmanage core update`. Es wird nichts kommentarlos gelöscht; alte Versionen werden gesichert.

### Was tun bei kaputter Installation oder Rechten?
Das Skript zieht eine frische Version, migriert Config/DB und versucht Rechte zu reparieren. Notfalls alte Version aus dem Backup-Verzeichnis zurückrollen.

### Kann ich weiter über die GUI updaten?
Ja. inmanage ist unabhängig, bietet aber versionierte Backups vor Updates.

### Automatisierte Backups?
Ja. `inmanage cron install` richtet Artisan- und Backup-Crons ein (prüfe Benutzer/Pfade). Alternativ manuell per crontab/cron.d.

### Config falsch/alt?
`.inmanage/.env.inmanage` anpassen oder löschen; wird bei Bedarf neu erstellt. Provisionierte Installs nutzen `.inmanage/.env.provision`.

### Docker?
Im Container mit korrekten Mounts/Shell für `www-data` ausführen. Rechte im Projektpfad setzen (775/owned by root:www-data o. ä.).

### Löscht eine Clean-Install mein altes Setup?
Nein. Alte App wird umbenannt, bevor eine neue abgelegt wird (nur mit Bestätigung/force).

### SQL aus Backup ziehen?
Im Backup-Verzeichnis:
```bash
tar -xf *YYYYMMDD*.tar.gz --wildcards '*.sql' --strip-components=6
```

### Nicht-standard .env?
`.env.provision` basiert auf einer Standard-.env, enthält aber temporär Elevated-DB-User. Nach Provisionierung werden diese Felder entfernt.

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
