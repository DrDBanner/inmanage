# INMANAGE – Invoice Ninja CLI

inmanage (inm) – CLI for Invoice Ninja

**Backup. Update. Install. Done.**

Inmanage is the CLI for self-hosted Invoice Ninja. Focus: **save time**, **less stress**, **certainty**, **convenience**. Installation takes 2–3 minutes and will save you many hours of manual work maintaining your Invoice Ninja instance.

**Full documentation:**
<https://github.com/DrDBanner/inmanage/blob/main/docs/index.md>

## Recommended Invoice Ninja CLI Installation Procedure

```bash
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | bash
```

The installer auto-selects the install mode (system when run as root, otherwise user).
- Full install: system-wide (requires sudo/root)
- Local install: user context (~/.local/bin)
- Project install: once per project

If you choose project mode, run the installer from your base directory.
For system installs via curl|bash, add `--mode system` and run with sudo.
User installs live in `~/.local/share/inmanage` (XDG).

Then go to your base directory and run the first command:

*Run as the webserver user to avoid permission issues when creating the project's config files and folders:*

```bash
cd /path/to/your/invoiceninja_basedirectory
sudo -u www-data inm core health
```

*If `sudo` isn't needed.*

```bash
inm core health
```
> [!NOTE]
> * Run the script as a user who can read the `.env` file of your Invoice Ninja installation. Typically, this is the web server user, such as `www-data`, `httpd`, `web`, `apache`, or `nginx`. In shared hosting environments, it is often the logged-in user (e.g., `u439534522`).
> * Ensure you set the correct username in the script’s `.env.inmanage` file under `INM_ENFORCED_USER` and especially on the first run (otherwise you'll need to change permissions afterwards).
> * In restricted environments (e.g., shared hosting with GitHub rate limits), set the `INM_GH_API_CREDENTIALS` variable in `.env.inmanage` as `USERNAME:PASSWORD` or `token:x-oauth` if needed.



If the installer created symlinks (system/user/project), you can use `inm` (short) or `inmanage`. Otherwise run the CLI from its install path; creating a project-local symlink is recommended.

*Typical directory structure:*

```text
/var/www/billing.yourdomain.com/            # The base-directory
├── .inmanage/                              # The Project's CLI Configuration directory. (automatically created)
├── .cache/                                 # Optional. Project Cache.
├── .backup/                                # Backups go here.
├── invoiceninja/                           # The current/future Invoice Ninja installation-directory
│   └── public/                             # Document root (set this as your web server root folder)
```

### Prerequisites

- BASH shell
- Working and configured webserver (e.g. Apache or Nginx)
- Access to the webserver user (e.g. www-data) or knowledge of who owns the Invoice Ninja files
- Valid credentials for the database (either via .env file or .my.cnf)
- Git (for fetching the script) and some other basic tools like `curl` `wc` `tar` `cp` `mv` `mkdir` `chown` `find` `rm` `grep` `xargs` `php` `touch` `sed` `sudo` `tee` `rsync` `awk` `jq` `git` `composer` `zip` `unzip` `sha256sum`
- Basic familiarity with command-line operations

## Recommended Invoice Ninja Installation Procedure (provisioned)

```bash
# 1. Run installation wizard
inm core install

# 2. Select provisioned by pressing enter
[ENTER]

# 3. 
# edit .inmanage/.env.provision; Then run the installer
inm core install --provision
```

## Core commands (examples)

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

## Safety notes

- No silent deletes: old installs are moved aside.
- Backups include checksums (SHA-256).
- Provisioned installs are repeatable and auditable.
- Hooks are available for pre/post install/update/backup (see docs).

## Extended docs

Full documentation:
<https://github.com/DrDBanner/inmanage/blob/main/docs/index.md>
