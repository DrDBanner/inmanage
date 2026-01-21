# INmanage Cheat Sheet

Quick reference for the INmanage CLI (inm).

README: [readme.md](./readme.md)

Docs:
- [docs/index.md](docs/index.md)
- [docs/index.md#containers--vms-onboarding](docs/index.md#containers--vms-onboarding)

## Install the CLI

User install:

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

## First Run (create CLI config)

Run as the user that owns the app files:

```bash
cd /path/to/base
sudo -u www-data inm
```

## Install / Update

Provisioned install (wizard):

```bash
inm core install
```

Provisioned install (existing file):

```bash
inm core install --provision
```

Update + rollback:

```bash
inm core update
inm core update --version="v5.12.45"
inm core update rollback --latest
```

## Backup / Restore

```bash
inm core backup
inm core backup --name="pre_migration" --compress=tar.gz
inm core restore --file="/path/to/bundle.tar.gz" --force
inm core restore rollback --latest
```

## Health

```bash
inm core health
inm core health --format=compact|full|failed
inm core health --check=APP,CLI
inm core health --fix-permissions --override-enforced-user
inm core health --notify-test
```

## Cron

Install jobs:

```bash
inm core cron install --jobs=artisan|backup|heartbeat|test|essential|all
inm core cron install --jobs=all --backup-time="03:24" --heartbeat-time="06:00" # Change execution time
```

Remove jobs (or the whole instance block):

```bash
inm core cron uninstall --jobs=heartbeat
inm core cron uninstall
```

## Env Helper

```bash
inm env get app APP_URL
inm env set app APP_URL="https://example.test"
inm env get cli INM_PATH_BASE_DIR
inm env set cli INM_NOTIFY_TARGETS_LIST="email"
```

## Cache / Versions

```bash
inm core versions
inm core get app --version="v5.12.45"
inm core get app
```

## Uninstall CLI

```bash
inm self uninstall
```

## Common Flags

```bash
--debug                   # Verbose logging
--debuglevel=2            # Verbose + shell trace (may show secrets)
--force                   # Skip prompts for destructive actions
--dry-run                 # Log intent, skip changes
--override-enforced-user  # Skip enforced user switch
--no-cli-clear            # Skip clear/logo
```

## Troubleshooting

```bash
inm core health --debug
inm core health --fix-permissions --override-enforced-user
```
