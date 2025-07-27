# INMANAGE – Invoice Ninja CLI

**Backup. Update. Install. Done.**

Manage your self-hosted Invoice Ninja instance from the command line. Fast, scriptable, safe. Includes backup, update, install, provisioning, and cron setup. All in one file.

**Takes ~2 minutes to set up. Saves hours later.**

Run `./inmanage.sh -h` for all commands and exhaustive options.

## Highlights

- Update Ninja with rollback, detached from GUI. Saves you resources.
- Backup DB and/or files with automatic retention.
- Install from scratch or provisioned `.env`
- Wizard for provisioned install (`install -h`)
- Snappdf auto-installer and auto updater.
- Smart mount-aware deployment. Atomic first, then fallback to copy strategy.
- Automatic Cleanup of old backups & versions.
- Import SQL dumps (`import_db -h`)
- Cron install helper (`install_cronjob -h`)
- Debug logging with `--debug`


---

## Quick Setup

```bash
cd /var/www/billing.example.com
sudo -u www-data git clone https://github.com/DrDBanner/inmanage.git .inmanage
sudo -u www-data .inmanage/inmanage.sh
```



**Folder layout:**

```plaintext
/var/www/billing.example.com/ #base directory
├── .inmanage/         # script
├── inmanage.sh        # symlink to script
├── invoiceninja/      # actual Invoice Ninja install
│   └── public/        # web root
```

Do **not** install the script inside the Ninja folder.

---

## Commands

```bash
./inmanage.sh <command> [--options]
```

| Command            | Description                                                   |
|--------------------|---------------------------------------------------------------|
| `update`           | Update Invoice Ninja to latest version                        |
| `backup`           | Backup DB and/or files (versioned)                            |
| `install`          | Create install config for unattended setup (Wizard)           |
| `create_db`        | Create a fresh database with user                             |
| `import_db`        | Import SQL dump into Invoice Ninja DB                         |
| `clean_install`    | Install from scratch (manual setup)                           |
| `cleanup`          | Removes old app version copies, clears old backups & caches   |
| `install_cronjob`  | Install artisan/backup cronjobs (see `install_cronjob -h`)    |

All commands support `-h` for detailed usage and arguments.

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
./inmanage.sh install
```

Runs an interactive wizard:

- Generates `.env`
- Downloads and installs latest version
- Creates DB/user (if configured)
- Runs setup & migrations
- Prompts for cron install & backup

Use `.env.provision` for prefilled config. Fields like `DB_ELEVATED_USERNAME` are removed after successful setup.

---

## Cron Setup

```bash
./inmanage.sh install_cronjob -h
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
0 2 * * * www-data /path/to/inmanage.sh backup >> /dev/null 2>&1
```

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

This sets up a shell function that changes into your Invoice Ninja base directory and executes the script as the designated user. If no corresponding passwordless sudo rule exists, the user will be prompted to enter their password.

Copy, customize, and paste the ✨ magic code ✨ below into the shell terminal to add a line to your `~/.bashrc` and make it available instant:

```bash
echo 'inmanage() { cd /your/base-directory && sudo -u www-data ./inmanage.sh "$@"; }' >> ~/.bashrc
source ~/.bashrc
```

Then call from anywhere:

```bash
inmanage -h
```

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
Run `inmanage backup --create-backup-script`

*A script named `backup_remote_job.sh` will be created in the current directory. Open it with the text editor of your choice and customize it as needed. A detailed explanation is included directly within the file.*

This command creates a template script that you can customize to securely collect files and folders from any machine with SSH access.  
It requires `rsync` and passwordless SSH access (via SSH key) to the remote server (e.g. your Invoice Ninja server).

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
