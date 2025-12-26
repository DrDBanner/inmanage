# INMANAGE – Invoice Ninja CLI
inmanage / inm – CLI for Invoice Ninja

**Backup. Update. Install. Done.**

Inmanage is the CLI for self-hosted Invoice Ninja. Focus: **save time**, **less stress**, **certainty**, **convenience**.

Docs: `docs/index.md` (see `docs/index.md`)

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | bash

# Follow the installation procedure then go to your basedirectory and run your first command.
cd /path/to/your/invoiceninja_basedirectory
inmanage core health
```

If the installer created symlinks (system/user/project), you can use `inmanage` or `inm`. Otherwise run the CLI from its install path; creating a project-local symlink is recommended.

## Recommended Invoice Ninja Installation Procedure (provisioned)

```bash
inmanage core provision spawn

# edit .inmanage/.env.provision; Then run the installer
inmanage core install --provision
```

## Core commands (examples)

```bash
inmanage core health
inmanage core install [--clean] [--provision] [--version=v]
inmanage core update [--version=v] [--force]
inmanage core backup [--name=label] [--compress=tar.gz|zip|false]
inmanage core restore --file=path [--force] [--include-app=true|false]
```

## Help

```bash
inmanage -h
inmanage core health -h
```

## Safety notes

- No silent deletes: old installs are moved aside.
- Backups include checksums (SHA-256).
- Provisioned installs are repeatable and auditable.
