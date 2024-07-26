# Backup | Update | Install - Invoice Ninja - MGM CLI Script 

Easily update, backup, and install your self-hosted Invoice Ninja instance with a CLI shell script. Maintenance and management has never been faster.

[![Install Invoice Ninja in 5 minutes](https://github.com/user-attachments/assets/adcecf2e-1cb7-471e-92cd-93e31443e7b6)](https://www.youtube.com/watch?v=SdOmEkSL9os)

### TOC -  Table of Content

- [Overview](#overview)
- [Installation](#mgm-script-installation)
- [Running the script](#running-the-script)
- [Commands](#commands)
- [What this script does](#what-this-script-does)
- [FAQ](#faq---frequently-asked-questions)

## Overview

This script manages your Invoice Ninja installation (version 5 and above) by performing updates, backups, cleanup tasks, and installations, including [Installation Provisioning](#installation-provisioning). On the first run, it helps you set up its `.env.inmanage` configuration file.

#### Key Features

* **Automated Updates**: Downloads and installs the latest version.
* **Installations**: Provisioned and clean options. 
* **Efficient Backups**: Manages backups with custom settings.
* **Docker Friendly**: Can be integrated in docker setups to deploy updates decoupled from webserver.
* **Maintenance Management**: Handles maintenance mode, cache clearing, and more.
* **Post-Update Tasks**: Includes data migration, optimization, and integrity checks.

## Prerequisites

* A running and configured webserver
* BASH Shell
* Credentials for the webserver and database
* A peek into the basics of Invoice Ninja mechanics ([Official Installation Documentation](https://invoiceninja.github.io/en/self-host-installation/))


## MGM Script Installation

Go to your **base directory** where the `invoiceninja` folder resides or shall reside. Then run:

```bash
sudo -u www-data bash -c "git clone https://github.com/DrDBanner/inmanage.git .inmanage && .inmanage/inmanage.sh"
```

   Ensure that `www-data` is the correct user (substitute if necessary) who has all the permissions to your Invoice Ninja installation, including reading its `.env` configuration file. 

   If you are in a shared hosting environment with SSH access, you'll most likely have to stick with the user you are logged in and this should/could be fine. Then you install this script with your current user/credentials like this:

```bash
git clone https://github.com/DrDBanner/inmanage.git .inmanage && .inmanage/inmanage.sh
```

And follow the installation wizard. You can accept defaults by pressing `[Enter]`. This will take no more than 30 seconds. After that you are ready to go. 

> [!NOTE]
> - Ensure you install in the base directory containing the `invoiceninja` folder to avoid file permission issues.
> - Run the script as a user who can read the `.env` file of your Invoice Ninja installation. Typically, this is the web server user, such as `www-data`, `httpd`, `web`, `apache`, or `nginx`.
> - Ensure you put its name into the script's `.env.inmanage` configuration file during installation or manually afterwards under $INM_ENFORCED_USER.
> - The script tries to ensure all needed CLI tools are available and will prompt you if something is missing.  

## Running the script

Once installed, you can run the script using the symlink in your base directory. For example:

```bash
sudo -u www-data bash -c "./inmanage.sh backup"
```

This example shows how to run the script in a bash as user `www-data`. This can be different on your machine. Like:

```bash
./inmanage.sh backup
```
If you already are the user with the corresponding permissions. 

> [!TIP]
> During the installation you have been asked which user shall execute this script. So, if you call it now and you are not that particular user, you'll get prompted to enter the password in order to switch to that user. 
>
> So, you probably want to call it with the right user from the get go.

Run the script with one of the following commands to perform the associated tasks:

```bash
./inmanage.sh update
./inmanage.sh backup

## As a one-liner:

./inmanage.sh backup && ./inmanage.sh update
```

Performing a backup prior to an update is a good cause. In case something goes wrong you can switch back to the last working version in no time by renaming the broken installation and putting the last working in place. Like this:

### Rollback
Let's assume your folder looks like this:
```bash
ls -la

drwxr-xr-x  15 web      vuser   49 20 Juli 22:55 invoiceninja
drwxr-xr-x  15 web      vuser   49 20 Juli 14:12 invoiceninja_20240720_141317
drwxr-xr-x  15 web      vuser   49 20 Juli 14:13 invoiceninja_20240720_225551
```

Rename like this:
```bash

mv invoiceninja invoiceninja_broken
mv invoiceninja_20240720_225551 invoiceninja

```

Ensure to substitute the numbers with the correct timestamps/foldername. Now your installation is in the last working state and you prevented downtime. 

### Run as cronjob

If you want to run it as a cronjob add this line to your crontab. Mind the user `www-data` here as well.

```bash
0 2 * * * www-data /path/to/your/inmanage.sh backup > /path/to/logfile 2>&1
```

   I would not update via cronjob. However, if you choose to automate updates with cron, you can include the `--force` flag in the `update` command to force the update, even if you are already on the latest version.

   - **With `--force` Flag:** The update will proceed regardless of the current version.
   - **Without `--force` Flag:** 
      - If no new version is available, the script will wait for user input for up to 60 seconds. If there is no response within this timeframe, the script will abort.
      - If a new version is available, the update will be performed automatically without requiring user interaction.

## Update the script

To update the script, use:

```bash
cd .inmanage && sudo -u www-data git pull
```

Note: Ensure you replace `www-data` with the appropriate user.

If you have installed the script as the user with the corresponding rights the command looks like this

```bash
cd .inmanage && git pull
```

## Commands

- **`clean_install`**:

  - Downloads and installs the latest version of Invoice Ninja from Github.
  - Target is the $INSTALLATION_DIRECTORY which must be set during installation in `.env.inmanage`
  - If the target folder already exists, it gets renamed and you start from scratch.
  - Creates a clean .env file
  - Generates the key into the .env file
  - Generates the cronjob string for you (must be installed manually)
  - Another powerful option is the [Provisioned Installation](#installation-provisioning) option. 

- **`update`**:

  - Downloads and installs the latest version of Invoice Ninja from Github.
  - Updates the installation.
  - Has a `--force` flag option.
  - Executes cleanups by default.

- **`backup`**:

  - Creates backups of the database and files, compresses them, and handles versioning.
  - Ensures the backup directory exists, performs the backup, and cleans up old backups.
  - Executes cleanups by default.

- **`cleanup_versions`**:

  - Deletes old versions of the Invoice Ninja installation directories.
  - Keeps only a specified number of recent versions defined in `INM_KEEP_BACKUPS` during installation.

- **`cleanup_backups`**:
  - Removes old backup files.
  - Keeps only a specified number of recent backups defined in `INM_KEEP_BACKUPS` during installation.

## What this script does

1.  #### Configuration File Setup:

   - If `.inmanage/.env.inmanage` file is not found, the script creates it and prompts for settings like installation directory, backup locations, and other configurations.

      You can provision the file manually

      ```bash
      # .inmanage/.env.inmanage configuration file

      INM_BASE_DIRECTORY="/your/base/directory/" # mind the trailing slash
      INM_INSTALLATION_DIRECTORY="./invoiceninja"
      INM_ENV_FILE="./invoiceninja/.env"
      INM_TEMP_DOWNLOAD_DIRECTORY="./.in_temp_download"
      INM_BACKUP_DIRECTORY="./_in_backups"
      INM_ENFORCED_USER="www-data"
      INM_ENFORCED_SHELL="/bin/bash"
      INM_PHP_EXECUTABLE="/usr/bin/php"
      INM_ARTISAN_STRING="/usr/bin/php /your/base/directory/./invoiceninja/artisan"
      INM_PROGRAM_NAME="InvoiceNinja" # Backup file name
      INM_KEEP_BACKUPS="2" # How many iterations to keep
      INM_FORCE_READ_DB_PW="N" # Read DB Password from installation or assume existing .my.cnf
      ````
   - #### Installation Provisioning

      During setup, the `.inmanage/.env.example` file is created, mirroring the standard `.env` file of Invoice Ninja. By pre-populating it with `APP_URL` and relevant `DB_` data, and renaming it to `.env.provision`, it becomes a trigger for automated provisioning. It's a good idea to populate the file with as much as configurations as possible from the get go. You can find valuable hints and options in the [Official Documentation for .env](https://invoiceninja.github.io/en/env-variables/) and [Mail](https://invoiceninja.github.io/en/self-host-installation/#mail-configuration).

      Next time you run the script, it performs the following tasks in one batch:

      - Creates the database and database user
      - Downloads and installs the tar file
      - Publishes the `.env.provision` template to `.env` for production use
      - Generates the application key
      - Migrates the database
      - Creates an admin user
      - Reminds you to set up cron jobs
      - Prompts you to create an initial backup

      **Basically, you save a huge amount of time.**

> [!IMPORTANT]
> Within the file `.inmanage/.env.example` are two crucial fields. DB_ELEVATED_USERNAME and DB_ELEVATED_PASSWORD. Fill these fields with credentials of a user that has the rights to create databases and the rights to give grants. In most cases this user is the database root user. Once the creation of the database and user were successful, these credentials do get removed from that file automatically.

[IN_CLI_PROVISIONED_INSTALL_vp9.webm](https://github.com/user-attachments/assets/889c0cb8-0362-4eb2-8939-97274c7ff4cc)

2. **Environment Variables**:

   - Loads values from `.env.inmanage` to configure paths, user settings, PHP executable, and other details.

3. **Command Check**:

   - Verifies that required commands (`curl`, `tar`, `php`, etc.) are installed and available on your system.

4. **User Check**:

   - Ensures the script is run under the correct user account to avoid permission issues. If you are not the correct user the script asks for your password and switches to that account.

5. **Reads Invoice Ninja Configuration**

   - The script reads data from the Invoice Ninja .env file to determine the database connection in order to execute the mysqldump. By default it assumes you have a working .my.cnf file which holds the database credentials. 
   
  > [!CAUTION]
  > If you have set `INM_FORCE_READ_DB_PW="Y"` in your configuration, then it will grab the password and pass it to the mysqldump command. Which CAN be a security issue. So, handle with care.

6. #### Updates Invoice Ninja

   - **Version Check**

      - Installed Version: Determines the currently installed version.
      - Latest Version: Compares the installed version to the most recent version available.

   - **User Interaction**

      - Up-to-date: If the installed version is up-to-date, it requires user interaction within 60 seconds to proceed with a re-update. A `--force` flag enables you to perform the update no matter what.
      - Outdated: If the installed version is outdated, it proceeds automatically without user interaction.

   - **Update Process**

      - Download: Downloads the latest *.tar file.
      - Unpack: Unpacks the downloaded file.
      - Maintenance Mode: Puts Invoice Ninja into maintenance mode.
      - Cache Management: Clears the caches.
      - Data Migration: Moves your data and settings.
      - Optimization: Runs artisan optimize.
      - Post-Update Scripts: Executes the necessary post-update scripts.
      - Database Migrations: Checks if database migrations are needed and performs them.
      - Data Integrity: Checks data integrity.
      - Translations: Grabs the latest translations.
      - Production Mode: Puts Invoice Ninja back into production mode.
      - Clean Up: Automatically cleans up old installation backups based on your settings.

6. #### Backup Invoice Ninja

   - **Checks**

      - **Target Directory** If present, it will be used. If not present, it will be created.
      - **Variables** Reads variables and credentials.

   - **User Interaction**

      - None

   - **Backup Process**

      - Dump: Dumps the database.
      - Compress: Compresses the Dump and the Invoice Ninja installation directory into one *.tar.gz file and stores it in the backup directory of your choice.
      - Versioning: Creates time-stamped filenames
      - Clean Up: Automatically Cleans up old backups based on your settings.

## Roadmap

Maybe I'll add some more functionality like ~~initial installation~~ and sync to external locations. We'll see.

Things I could imagine:

- [🍒] ~~Invoice Ninja installation from scratch with distribution based templates~~ 
- [🍒] Sync and push
- [🍒] Pre- and Post- Hooks with callbacks for external management software or notifications
- [🍒] Multi instance support within one base directory
- [🍒] Multi instance support with multiple base directories 
- [🍒] Management console for managing X instances (provision, monitor, updates, license status)

### Thoughts on push targets and sync functionality

I have thought about adding a push/sync function so that backups can be sent to a destination, but the more I think about it, it makes more sense not to, at least at this moment in time. Because in most cases you probably want to transfer a copy to your local network and not synchronize it to a backup server that is available on the internet. 

Therefore, it makes much more sense to me to select the backup target directory so that it is monitored by software such as [Nextcloud](https://nextcloud.com/) and, in the event of changes, transfers them to your local infrastructure. Have a look at [Nexctcloud GitHub](https://github.com/nextcloud) as well.

Other solutions may be:

- [rclone](https://rclone.org) (If you need to sync to OneDrive)
- [Syncthing](https://syncthing.net) 
- rsync (Available on any linux system)

The other option, since we are on a web server, is to make the backup target directory available under a specific URL. Of course, you will not forget to do this in a secure environment, i.e. with the help of user data that not everyone knows.

If you tell me, "No, no ... completely different" then I would think again about creating a cool solution.

## Limitations

Currently, the script is designed to manage a single installation. If you have multiple instances to manage, you'll most probably have them running in different base directories. So, you install this script for each instance. 

If you have multiple instances running under the same base directory this script would need to get extended to handle multiple .env.inmange files and a kind of router to manage each instance individually and/or in one batch.

## FAQ - Frequently asked questions

### So, how does your script work on an existing installation? Does it start everything from scratch, does it delete something?

Installation process of the MGM script is the same; But you just do not install any new Invoice Ninja instance. You use the command-line switches for “backup” and “update” → [Commands](#commands) 
      
If you accidentially run the `clean_installation` or the `provisioned installation` process within an existing installation you get prompted, if you really really want to continue, since there’s already a folder. If you insist with YES here, the old folder gets renamed. So nothing gets deleted.

### What about non-standard .env files or at least less common ones? Are the details copied over into the new .env? 

The `.env.provision` file is a template generated from a standard `.env`, but it has 2 extra added fields for creating databases. Once it has been processed this `.env.provision` file becomes a normal `.env` file and gets moved over into a new installation. It’s its only purpose -create new installations. So, in an existing environment it’s just nothing you need to take care of. But if you use it as a kickstarter for a new installation everything you put in there gets copied over -except the DB_ELEVATED_* fields.

### I already have multiple cronjobs setup, does it still generate those?
 
This script does not backup any cronjobs nor does it register new ones. It just gives you the exact minimum cronjob line you need after an initial install.

## Contribs

The beloved Invoice Ninja
https://github.com/invoiceninja/invoiceninja

### Donations

If you feel you'd like to donate something for this script go for it:

- **Bitcoin [BTC]** bc1qj3tpz90q3m9hyw8q6qgkdswgk68k34aktehr2h
- **Bitcoin Cash [BCH]** 1DucLq4AJP5R53qMT9iRZnAveA17DQyCdp
- **Tether ETH** 0xA4099E3783578c490975d12d5680F1Aa739DD5d1
- **Tether SOL** G1RBqC7zZJSPQQ1gQ5DUSNksS3ZGFXHPYKfkqYN6eG36
- **Doge [DOGE]** DM2LAxAyC4Ug7mBpaGAnYygerX8RtZdxom
- **Tron [TRX]** TXkVPuKfTiaSz3mtMZ9NTqhEH6EW7bF3gC
