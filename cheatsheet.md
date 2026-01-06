# INmanage Cheat Sheet

Quick reference for the INmanage CLI (inm).

README: [readme.md](./readme.md)

Docs:
- https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
- https://github.com/DrDBanner/inmanage/blob/main/docs/index.md#containers--vms-onboarding

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | bash
```

System install:

```bash
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | sudo bash
```

Project install:

```bash
cd /path/to/base
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | bash -s -- --mode project
```

## First Run

```bash
cd /path/to/base
sudo -u www-data inm
```

## Health / Info

```bash
inm core health
inm core health --fix-permissions
```

## Install / Update

```bash
inm core install
inm core install --provision
inm core update
inm core update --version=v5.7.4
inm core update rollback --latest
```

## Backup / Restore

```bash
inm core backup
inm core backup --name=label --compress=tar.gz|zip|false
inm core restore --file=/path/to/bundle.tar.gz --force
inm core restore rollback --latest
```

## Cache / Versions

```bash
inm core versions
inm core get app --version=v5.7.4
inm core get app
```

## Cron

```bash
inm core cron install
inm core cron uninstall
inm core cron install --jobs=artisan|backup|heartbeat|essential|all
```

## Env Helper

```bash
inm env get app DB_HOST
inm env set app APP_URL=https://example.test
inm env get cli INM_BASE_DIRECTORY
```

## Common Flags

```bash
--debug                   # Verbose logging
--debuglevel=2            # Verbose + shell trace (may show secrets)
--dry-run                 # Log intent, skip changes
--override-enforced-user  # Skip enforced user switch
--no-cli-clear            # Skip clear/logo
```

## Troubleshooting

```bash
inm core health --debug
inm core health --fix-permissions --override-enforced-user
```
