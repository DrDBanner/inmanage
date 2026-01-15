# INmanage – Invoice Ninja CLI

INmanage (inm) – CLI for Invoice Ninja

**Backup. Update. Install. Done.**

INmanage is the CLI for self-hosted Invoice Ninja. Focus: **save time**, **less stress**, **certainty**, **convenience**. Installation takes 2–3 minutes per host and will save you many hours of manual work maintaining your Invoice Ninja instances. 

> [!TIP]
> - **Full documentation**: [docs/index.md](docs/index.md)
> - Cheat sheet: [cheatsheet.md](./cheatsheet.md)

## Things You Need

| Requirement | Notes |
| --- | --- |
| Bash | Required shell. |
| Webserver | Apache or Nginx. |
| File owner user | User that owns the Invoice Ninja files (often the webserver user). |
| DB credentials | From `.env` or `.my.cnf`. |
| CLI tools | git, curl, tar, rsync, php, jq, composer, zip/unzip. |

## Quickstart

Detailed installation options and different install modes: see the [Installation Documentation](docs/index.md#install-cli).

```bash
# 1) Install CLI (from anywhere; system mode;)
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | sudo bash
```
![install](https://github.com/user-attachments/assets/e523ee13-15aa-4858-8eef-e007e393af1d)

```bash
# 2) First run - create project config
cd /path/to/your/invoiceninja_basedirectory
sudo -u www-data inm

# 3) Verify system environment readiness
sudo -u www-data inm core health

# 4) Install Invoice Ninja (fill in the configuration)
sudo -u www-data inm core install
```

> [!NOTE]
> Example: base directory `/var/www/billing.yourdomain.com`, app directory `/var/www/billing.yourdomain.com/invoiceninja`.
>
> Learn naming: [docs/index.md#project-layout-inmanage](docs/index.md#project-layout-inmanage)
>
> Replace `www-data` with your webserver user if needed. If you don't need sudo, you can leave it out.


If the installer created symlinks (system/user/project), you can use `inm` (short) or `inmanage`. Otherwise run the CLI from its install path with `./inm` or `./inmanage`.

If `sudo` isn't needed:

```bash
inm
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
> - Full documentation: [docs/index.md](docs/index.md)
> - Cheat sheet: [cheatsheet.md](./cheatsheet.md)
> - Containers/VMs: [docs/index.md#containers--vms-onboarding-invoice-ninja-and-inmanage](docs/index.md#containers--vms-onboarding-invoice-ninja-and-inmanage)

## What You Get (incl. safety notes)

Short list below; each item is explained in the extended docs.

- **Install** repeatable full installs via config file (provisioned), designed for staging/production.
- **Update** safe updates with instant rollback, verified download integrity, and automatic pre‑update DB backups.
- **Migrate** easy flow to migrate Invoice Ninja from one host to another.
- **Backup** backups with checksums (SHA‑256) and restore (bundle or DB‑only).
- **Health** checks for server readiness and ongoing integrity (system, app, PHP, DB, filesystem, cron, network, PDF/Snappdf).
- **Heartbeat** notifications (email/webhook) for non‑interactive failures.
- **Cron** automatic essential jobs on provisioned installs (artisan + backup); heartbeat optional. Includes per‑instance cron blocks.
- **Permissions** enforcement and fix‑permissions helper for any environment.
- **Config** CLI + app config helpers (`inm env get/set`) for both CLI and app settings.
- **DB** tooling (create/import/purge, DB‑only backup) with .my.cnf support.
- **CLI** lifecycle (self‑update and uninstall) for system/user/project installs.
- **Options** extensive switches across all commands (safe defaults, explicit overrides).
- **Hooks** before/after install, update, and backup for automation.
- **Ops** history log for auditability, plus caching and version management.

## Licensing

INmanage is free to use and built for professional operations where time savings and operational safety matter.

If you use INmanage as part of a **paid or commercial service**, supporting
the project with a Commercial Support License is voluntary, appreciated, and
considered professional best practice.

Details: see [LICENSING.md](./licensing.md)
