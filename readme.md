# INMANAGE – Invoice Ninja CLI

inmanage (inm) – CLI for Invoice Ninja

**Backup. Update. Install. Done.**

Inmanage is the CLI for self-hosted Invoice Ninja. Focus: **save time**, **less stress**, **certainty**, **convenience**. Installation takes 2–3 minutes and will save you many hours of manual work maintaining your Invoice Ninja instance.

**Full documentation:**
<https://github.com/DrDBanner/inmanage/blob/main/docs/index.md>

Things you need

- Bash shell
- A working webserver (Apache or Nginx)
- The user that owns the Invoice Ninja files (often the webserver user)
- Database credentials (from `.env` or `.my.cnf`)
- Common CLI tools (git, curl, tar, rsync, php, jq, composer, zip/unzip, etc.)

## Invoice Ninja CLI - Installation Procedure

Per user:

```bash
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | bash
```

The installer auto-selects the install mode (system when run as root, otherwise user).

- System install: run with sudo; installs to `/usr/local/share/inmanage`, symlinks in `/usr/local/bin`.
- User install: default without sudo; installs to `~/.local/share/inmanage`, symlinks in `~/.local/bin`.
- Project install: run from your base directory; installs to `./.inmanage/cli`, symlinks in the project root.

Optional for system installs:
- `--install-owner USER:GROUP` to set ownership (e.g. `root:vuser`)
- `--install-perms DIR:FILE` to set permissions (e.g. `775:664`)

Per project:

```bash
cd /path/to/your/invoiceninja_basedirectory
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | bash -s -- --mode project
```

Per system:

```bash
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | sudo bash
```

Per system with ownership/permissions (optional):

```bash
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | sudo bash -s -- --mode system --install-owner=root:vuser --install-perms=775:664
```
*Ownership/permissions may be required so your current user can read the installed CLI version and update it if needed.*



First run (creates `.inmanage/.env.inmanage` and folders):

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

*Typical directory structure:*

```text
/var/www/billing.yourdomain.com/            # The base-directory
├── .inmanage/                              # The Project's CLI Configuration directory. (automatically created)
│   └── cli/                                # Optional binaries folder if project wide installation
├── .cache/                                 # Optional. Local Project Cache.
├── .backup/                                # Backups go here.
├── invoiceninja/                           # The current/future Invoice Ninja installation-directory
│   └── public/                             # Document root (set this as your web server root folder)
```



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
