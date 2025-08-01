# INMANAGE - Invoice Ninja - Management Script

*Backup | Update | Install*

Easily manage your self-hosted Invoice Ninja instance with a CLI shell script. Perform updates, backups, clean installations, and provisioning with minimal effort.

**Installation takes just 2–3 minutes and will save you many hours of manual work later.**

If you seek a very convenient, fast, and optionally automated way to install Invoice Ninja from scratch: Go with the [Provisioned Installation](#provisioned-invoice-ninja-installation) option.


[![Install Invoice Ninja in 5 minutes](https://github.com/user-attachments/assets/adcecf2e-1cb7-471e-92cd-93e31443e7b6)](https://www.youtube.com/watch?v=SdOmEkSL9os)

*Click image for video.*

## Table of Contents

* [Install the Script](#install-the-script)
* [Run the Script](#run-the-script)
* [Update the Script](#update-the-script)
* [Commands Overview](#commands)
* [Configuration](#configuration)
* [FAQ](#faq)
* [Rollback](#rollback)
* [Cronjob](#cronjob)
* [Extract SQL](#extract-sql)

## Prerequisites

* BASH shell
* A working and configured webserver (e.g. Apache or Nginx)
* Access to the webserver user (e.g. `www-data`) or knowledge of who owns the Invoice Ninja files
* Valid credentials for the database (either via `.env` file or `.my.cnf`)
* Git installed (for fetching the script)
* Basic familiarity with command-line operations

### Features

* *Automated Updates*
* *Provisioned/Clean Installations*
* *Versioned Backups*
* *Docker Compatible* (partial)
* *Maintenance Handling*
* *Post-Update Checks*
* *Automatic Snappdf updates*

## Install the Script

*To ensure proper functionality and avoid permission or backup issues, use the following directory structure:*

```
/var/www/billing.yourdomain.com/            # The base-directory
├── .inmanage/                              # The script-directory (cloned here)
├── inmanage.sh -> .inmanage/inmanage.sh    # Symlink automatically created by the script
├── invoiceninja/                           # The current/future Invoice Ninja installation-directory
│   └── public/                             # Webroot (set this as your web server root-folder)
```

Make sure you change into your `base-directory` when you clone the script. The symlink `inmanage.sh` is created into this directory so that you can easily call the script via `./inmanage.sh` without referencing the `.inmanage` subfolder.

> [!WARNING]
> Do **not install inside** the Invoice Ninja `installation-directory`. The script must to reside next to it.

### With Sudo – Webserver user (recommended):

```bash
sudo -u www-data git clone https://github.com/DrDBanner/inmanage.git .inmanage &&
sudo -u www-data .inmanage/inmanage.sh
```

Ensure the specified user (e.g. `www-data`) has access to the `invoiceninja` folder and its `.env`.

### As current user:

```bash
git clone https://github.com/DrDBanner/inmanage.git .inmanage && .inmanage/inmanage.sh
```

## Run the Script

Run with correct permissions:

```bash
sudo -u www-data ./inmanage.sh backup
```

Or if already correct user:

```bash
./inmanage.sh backup
```

> [!TIP]
> If you have issues to run the script, e.g. on FreeBSD you'll most likely need to run it like this: 
> ```
> sudo -u web /usr/iports/bin/bash -c "/usr/iports/bin/bash ./inmanage.sh backup"
> ```

> [!NOTE]
> * Run the script as a user who can read the `.env` file of your Invoice Ninja installation. Typically, this is the web server user, such as `www-data`, `httpd`, `web`, `apache`, or `nginx`. In shared hosting environments, it is often the logged-in user (e.g., `u439534522`).
> * Ensure you set the correct username in the script’s `.env.inmanage` file under `INM_ENFORCED_USER`.
> * In restricted environments (e.g., shared hosting with GitHub rate limits), set the `INM_GH_API_CREDENTIALS` variable in `.env.inmanage` as `USERNAME:PASSWORD` or `token:x-oauth` if needed.

### Register Global Command - Example

This sets up a shell function that changes into your Invoice Ninja base directory and executes the script as the designated user. If no corresponding passwordless sudo rule exists, the user will be prompted to enter their password.

Copy, customize, and paste the ✨ magic code ✨ below into the shell terminal to add a line to your `~/.bashrc` and make it available instant:

```bash
echo 'inmanage() { cd /your/base-directory && sudo -u www-data ./inmanage.sh "$@"; }' >> ~/.bashrc
source ~/.bashrc
```

Then call from anywhere:

```bash
inmanage update
```

## Update the Script

Update with correct user:

```bash
cd .inmanage && sudo -u www-data git pull
```

Or:

```bash
cd .inmanage && git pull
```

## Commands

* `clean_install`

  * Installs a fresh copy of Invoice Ninja
  * Renames any existing target folder and creates a new target folder
  * Downloads and extracts latest release
  * Creates a new `.env` file and generates application key
  * Suggests required cronjob for schedule execution

* `update`

  * Creates versioned snapshot of the current installation-directory status
  * Downloads and installs latest version
  * Copies over data from the data storage
  * Takes care of existing *.ini and .htaccess files
  * Optional `--force` bypasses version check
  * Handles maintenance
  * Handles DB migrations
  * Ensures file permissions
  * (Re-)Installs Snappdf
    * Server must satisfy dependencies (e.g. for Debian 12 [like this](https://github.com/DrDBanner/inmanage/blob/main/docs/tutorials/install_invoiceninja_debian12_bookworm_vm.md#8-additional-software))
    * `PDF_GENERATOR=snappdf` must be set in Invoice Ninja `.env` configuration file.
    * If a custom `chromium-path` is set in `.env` it will skip the download of new sources   


* `backup`

  * Dumps DB, compresses files, stores with timestamp

* `cleanup_versions`

  * Deletes older installation directories beyond `INM_KEEP_BACKUPS`

* `cleanup_backups`

  * Deletes older backups beyond `INM_KEEP_BACKUPS`

## Functionality Summary

| Task                | Description                                         |
| ------------------- | --------------------------------------------------- |
| Config File Setup   | Creates `.env.inmanage` on first run                |
| Backup              | Dumps DB, compresses files, timestamps and rotates  |
| Update              | Version check, update logic, cache + DB ops         |
| Clean Install       | Renames old, installs fresh, applies default config |
| Provisioned Install | Automates DB setup, install, `.env` setup           |

## Configuration

When the script is run for the first time and `.inmanage/.env.inmanage` does not exist, a setup wizard will launch automatically. It will automatically detect most values (just press \[ENTER] to accept) but you can optionally change installation path, user, database handling options, and backup location. You can later modify the file manually, or delete it to start from scratch.

Example `.inmanage/.env.inmanage`:

```bash
INM_BASE_DIRECTORY="/var/www/"
INM_INSTALLATION_DIRECTORY="./invoiceninja"
INM_ENV_FILE="./invoiceninja/.env"
INM_TEMP_DOWNLOAD_DIRECTORY="./.in_temp_download"
INM_BACKUP_DIRECTORY="./_in_backups"
INM_KEEP_DBTABLESPACE="N"
INM_ENFORCED_USER="www-data"
INM_ENFORCED_SHELL="/bin/bash"
INM_PHP_EXECUTABLE="/usr/bin/php"
INM_ARTISAN_STRING="/usr/bin/php ./invoiceninja/artisan"
INM_PROGRAM_NAME="InvoiceNinja"
INM_KEEP_BACKUPS="2"
INM_FORCE_READ_DB_PW="N"
INM_GH_API_CREDENTIALS=""
```

## Provisioned Invoice Ninja Installation
[IN_CLI_PROVISIONED_INSTALL_vp9.webm](https://github.com/user-attachments/assets/b29fcc10-752f-4b71-923d-f734c5a4f204)

*Click image for provisioned install video.*

A clean `.env.example` file is already included in the cloned `script-directory`. To perform a provisioned installation of Invoice Ninja, fill in values such as `APP_URL` and the required `DB_*` variables in `.env.example`, save it, then rename or copy it to `.env.provision` into the same directory.

On the next run of the script, without any parameters, the script will:

* Create the database and database user
* Remove elevated database credentials from `.env.provision`
* Determine, download, and install the latest Invoice Ninja release
* Move `.env.provision` to `.env`
* Generate the application key
* Run database migrations and seed the database
* Warm up the cache
* Create an admin user
* Suggest a cronjob and prompt for initial backup

> [!NOTE]
> Make sure to add `DB_ELEVATED_USERNAME` and `DB_ELEVATED_PASSWORD` to `.env.provision` if the script should create the Invoice Ninja database and user based on the values in the DB_* fields. These `*_ELEVATED_*` credentials will be automatically removed from the file once setup is complete.
If omitted, the script assumes the database and user already exist, and the corresponding `DB_*` values must be configured accordingly.

### Register Invoice Ninja scheduler cronjob
After a successful installation you need to register the scheduler via cronjob:
 
**Example for cron.d setup**

Copy, modify, and paste this code to create a cron.d file:

```bash
echo '* * * * * www-data /usr/bin/php /var/www/billing.yourdomain.com/invoiceninja/artisan schedule:run >> /dev/null 2>&1' | sudo tee /etc/cron.d/invoiceninja
```

**Example for crontab setup**

Copy, modify, and paste this code after you invoked `crontab -e` as a given user other than `root` keep in mind this user must have the corresponding file-permissions.

```bash
* * * * * php /var/www/billing.yourdomain.com/invoiceninja/artisan schedule:run >> /dev/null 2>&1
```

## Rollback

Restore older version:

```bash
mv invoiceninja invoiceninja_broken
mv invoiceninja_20240720_225551 invoiceninja
```

## Cronjob

If you create a cronjob you need to know which context you use. If you register a cronjob within `/etc/cron.d/` you need to provide the executing user (e.g. www-data) within the cron string. If you create a cronjob via `crontab -e` you must omit the user in the string, otherwise the cronjob would not run.

Backup example:

```bash
0 2 * * * www-data /path/to/inmanage.sh backup > /path/to/logfile 2>&1
```

Avoid update via cron unless using `--force`. Without it, script may block waiting for input.

**How do I install the Invoice Ninja scheduler cronjob?**

A complete explanation can be found under [Register Invoice Ninja scheduler cronjob](#register-invoice-ninja-scheduler-cronjob)

## Extract SQL

Extract `.sql` without unpacking full archive:

```bash
tar -xf InvoiceNinja_20250219_*.tar.gz --wildcards '*.sql' --strip-components=6
```

## FAQ

### Can I use this script if Invoice Ninja is already installed manually?

Yes. Install the script as described, run a backup, then run a forced update. Nothing is deleted or overwritten unexpectedly.

### Can I use this script if my installation is broken or has permission issues?

Yes. The script will move your old installation, pull a fresh version, and reapply the configuration. If needed, it will attempt to fix permission issues.

### Can I continue using the Invoice Ninja GUI for updates?

Yes. The script works independently. However, the script allows you to perform versioned backups before any update.

### Can I use this script for automated backups?

Yes. Add a cronjob as shown in the [Cronjob](#cronjob) section.

### How do I install the Invoice Ninja scheduler cronjob?

A complete explanation can be found under [Register Invoice Ninja scheduler cronjob](#register-invoice-ninja-scheduler-cronjob)

### What if I made a mistake during the installation wizard?

Edit or delete `.inmanage/.env.inmanage`. The script will regenerate it if missing.

### What about Docker and write permissions?

Ensure the script runs inside the correct container with appropriate mount settings. Grant `www-data` a shell and file write permissions as described in [Docker Notes](#docker-notes).

### Does the script delete my old setup when I run a clean install?

No. It renames the old folder before creating a new one. Manual confirmation is required.

### Does the script support multiple cronjobs or manage them?

No. It prints out the cronjob you should use, but does not install or track cronjobs itself.

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

### Limitations

* **Mounted volumes:** In Docker setups, Invoice Ninja storage paths are typically mounted. This prevents operations like moving or renaming directories, which the script relies on (e.g., for updates and backups). A workaround is planned.
* **User shell and permissions:** The `www-data` user typically lacks a login shell. This must be explicitly set (`usermod -s /bin/bash www-data`) for the script to function correctly.
* **Backup location:** Recommended backup path in Docker: `./html/storage/app/public/_in_backups`, which is within persisted volume scope.

## Donations

If you'd like to support this tool, here are the donation addresses:

* **Bitcoin \[BTC]** bc1qj3tpz90q3m9hyw8q6qgkdswgk68k34aktehr2h
* **Bitcoin Cash \[BCH]** 1DucLq4AJP5R53qMT9iRZnAveA17DQyCdp
* **Tether \[ETH]** 0xA4099E3783578c490975d12d5680F1Aa739DD5d1
* **Tether \[SOL]** G1RBqC7zZJSPQQ1gQ5DUSNksS3ZGFXHPYKfkqYN6eG36
* **Doge \[DOGE]** DM2LAxAyC4Ug7mBpaGAnYygerX8RtZdxom
* **Tron \[TRX]** TXkVPuKfTiaSz3mtMZ9NTqhEH6EW7bF3gC0xA4099E3783578c490975d12d5680F1Aa739DD5d1
