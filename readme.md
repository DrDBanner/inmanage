# Invoice Ninja Management Script

Easily update and back up your self-hosted Invoice Ninja instance with a shell script.

This script is designed to manage your Invoice Ninja installation starting from version 5 and above by performing updates, backups, and cleanup tasks. It uses a configuration file to set up necessary environment variables and ensure required commands are available. On the first start, it will help you set up the configuration.

When you call the script, do it as a user who has the rights to read the `.env` file of your Invoice Ninja installation. Most likely, it's the webserver's user, such as `web`, `apache`, or `nginx`. For example:

## Interactions

### Installation

Go to your base directory where the `invoiceninja` folder resides. Then run:

```bash
sudo -u web bash -c "git clone https://github.com/DrDBanner/inmanage.git .inmanage && chmod +x .inmanage/inmanage.sh && bash .inmanage/inmanage.sh"
```

Ensure that "web" is the correct user (substitute if necessary) who has all the permissions to your Invoice Ninja installation, including reading the .env file.

### Running the script

If everything went well with your installation, you now have a symlink in your base directory from which you can call the script directly. For example:

```bash
sudo -u web bash -c "bash ./inmanage.sh backup"
```

This example shows how to run the script in a bash as user 'web'. This can be different on your machine. During the installation you have been asked which user shall execute this script. So, if you call it now and you are not that particular user, you'll get prompted to enter the password in order to switch to that user. So, you probably want to call it with the right user from the get go.

### Update the script

You can update the script with

```bash
cd .inmanage && sudo -u web git pull
```

Mind the user 'web' here as well.

### Run as cronjob

If you want to run it as a cronjob add this line to your crontab. Mind the user 'web' here as well.

```bash
0 2 * * * web /path/to/your/inmanage.sh backup > /path/to/logfile 2>&1
```

## Key Functions

A little overview what's happening under the hood.

1. **Configuration File Setup**:

   - If `.env.inmanage` is not found, the script creates it and prompts for settings like installation directory, backup locations, and other configurations.

2. **Environment Variables**:

   - Loads values from `.env.inmanage` to configure paths, user settings, PHP executable, and other details.

3. **Command Check**:

   - Verifies that required commands (`curl`, `tar`, `php`, etc.) are installed and available on your system.

4. **User Check**:

   - Ensures the script is run under the correct user account to avoid permission issues.

5. **Reads Invoice Ninja Configuration**

- The script reads data from the IN .env file to determine the database connection in order to execute the mysqldump. By default it assumes you have a working .my.cnf file which holds the database credentials. If you have set `INM_FORCE_READ_DB_PW="Y"` in your configuration, then it will grab the password and pass it to the mysqldump command. Which CAN be a security issue. So, handle with care.

## Commands

- **`update`**:

  - Downloads and installs the latest version of Invoice Ninja from Github.
  - Updates the installation, copies environment files, and updates storage settings. With a `--force` switch you can force to re-run the update task even if you are on the most recent version.
  - Executes cleanups by default.

- **`backup`**:

  - Creates backups of the database and files.
  - Ensures the backup directory exists, performs the backup, and cleans up old backups.
  - Executes cleanups by default.

- **`cleanup_versions`**:

  - Deletes old versions of the Invoice Ninja installation directories.
  - Keeps only a specified number of recent versions defined in `INM_KEEP_BACKUPS` during installation.

- **`cleanup_backups`**:
  - Removes old backup files.
  - Keeps only a specified number of recent backups defined in `INM_KEEP_BACKUPS` during installation.

## Execution

Run the script with one of the following commands to perform the associated tasks:

```bash
./inmanage.sh update
./inmanage.sh backup
./inmanage.sh cleanup_versions
./inmanage.sh cleanup_backups
```

## Roadmap

Maybe I'll add some more functionality like initial installation and sync to external locations. We'll see.

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
