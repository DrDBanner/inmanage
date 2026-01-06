# Docker + INmanage (3 paths)

UNTESTED

This is the **copy/paste** Docker guide. It has three parts:

1) **Base stack** (nginx + DB + redis) → in **Shared basics** below.
2) **One INmanage path** (pick 1/2/3).
3) **Install Invoice Ninja** (same steps for all paths).

What you are building:
- **nginx** serves HTTPS and forwards PHP requests to **app**.
- **app** runs PHP‑FPM and holds the Invoice Ninja codebase.
- **db** stores data; **redis** handles cache/queues/sessions.
- **INmanage** runs inside **app** (Path 1/3) or a **sidecar** (Path 2).

Expected directory layout (with comments):

```text
your-docker/                    # project folder
├─ docker-compose.yml           # base stack (nginx + db + redis)
├─ .env                         # compose-only DB variables
├─ nginx/
│  ├─ inmanage.conf             # nginx vhost (HTTPS + PHP proxy)
│  └─ certs/                    # TLS certs
│     ├─ fullchain.pem
│     └─ privkey.pem
├─ Dockerfile.inmanage          # Path 1/2 only (adds tools + INmanage)
├─ docker-compose.override.yml  # Path 1/2 only (app/sidecar build)
├─ Dockerfile.custom            # Path 3 only (full custom runtime image)
└─ docker-compose.custom.yml    # Path 3 only (app build override)
```


If you are unsure, start with **Path 1**.

Back to main docs:
[docs/index.md](./../index.md#containers--vms-onboarding-invoice-ninja-and-inmanage)

## Is INmanage worth it in Docker?

Short answer: **yes if you want predictable ops**.

Benefits:
- One‑command backups/restore with rollback.
- Health checks + heartbeat mail.
- Repeatable updates (app + tooling) and audit history.

Costs:
- One‑time setup and a few extra volumes.
- Slightly more moving parts (especially with a sidecar/custom image).

Skip it if you are happy with manual updates/backups and do not need health reporting.

## Table of contents

- [Docker + INmanage (3 paths)](#docker--inmanage-3-paths)
  - [Is INmanage worth it in Docker?](#is-inmanage-worth-it-in-docker)
  - [Table of contents](#table-of-contents)
  - [Shared basics (all paths)](#shared-basics-all-paths)
  - [Path 1: Derived image](#path-1-derived-image)
  - [Path 2: Sidecar (app image untouched)](#path-2-sidecar-app-image-untouched)
  - [Path 3: Custom image (advanced)](#path-3-custom-image-advanced)
  - [Install Invoice Ninja (all paths)](#install-invoice-ninja-all-paths)
  - [After install (updates + health)](#after-install-updates--health)
  - [Operational notes](#operational-notes)

## Shared basics (all paths)

Start here. Create these files in a new empty folder. Then pick a path.

1) Create `docker-compose.yml`:

```yaml
services:
  app:
    image: invoiceninja/invoiceninja-debian:${TAG:-latest}
    restart: unless-stopped
    volumes:
      - app_public:/var/www/html/public
      - app_storage:/var/www/html/storage
      - app_inmanage:/var/www/.inmanage
      - app_backup:/var/www/.backup
      - app_cache:/var/www/.cache
    depends_on:
      - db
      - redis

  nginx:
    image: nginx:stable
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/inmanage.conf:/etc/nginx/conf.d/default.conf:ro
      - ./nginx/certs:/etc/nginx/certs:ro
      - app_public:/var/www/html/public:ro
      - app_storage:/var/www/html/storage:ro
    depends_on:
      - app

  db:
    image: mariadb:10.11
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
      MARIADB_DATABASE: ${DB_DATABASE}
      MARIADB_USER: ${DB_USERNAME}
      MARIADB_PASSWORD: ${DB_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql

  redis:
    image: redis:7
    restart: unless-stopped
    volumes:
      - redis_data:/data

volumes:
  app_public:
  app_storage:
  app_inmanage:
  app_backup:
  app_cache:
  db_data:
  redis_data:
```

Already have a stack? Keep it, but ensure service names match (`app`, `db`, `redis`) or adjust the provision file accordingly.

Why these volumes:
- `public`/`storage` keep uploads, logs, and generated files.
- `.inmanage` keeps CLI config + history.
- `.backup` keeps backups across restarts.
- `.cache` avoids re-downloads (saves time/RAM spikes).

Note: `:ro` is only for nginx (read‑only). The app container still has full write access to the same volumes.

2) Create `.env` (Compose variables only):

```env
DB_ROOT_PASSWORD=change-me-root
DB_DATABASE=ninja
DB_USERNAME=ninja
DB_PASSWORD=change-me
```

This `.env` is for Docker Compose only (DB container). The app `.env` is created by INmanage inside `/var/www/html`.

3) Create `nginx/inmanage.conf` (HTTPS on):

```nginx
server {
    listen 80;
    server_name billing.example.test;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name billing.example.test;
    root /var/www/html/public;
    index index.php;
    client_max_body_size 1024M;

    ssl_certificate /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        fastcgi_pass app:9000;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
```

4) Provide TLS certs (real or self‑signed). Example (dev):

```bash
mkdir -p nginx/certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout nginx/certs/privkey.pem \
  -out nginx/certs/fullchain.pem \
  -subj "/CN=billing.example.test"
```

5) Start the stack:

```bash
docker compose up -d
```

You are done with the base stack above. Now pick **one** path below. Everything after that uses the same install/update commands.

Quick pick:
- Path 1: [Derived image](#path-1-derived-image)
- Path 2: [Sidecar](#path-2-sidecar-app-image-untouched)
- Path 3: [Custom image](#path-3-custom-image-advanced)

## Path 1: Derived image

Keep the official app image, add the missing tools.

Pros:
- Minimal moving parts; simple to update.
- Tools persist across rebuilds.
- Low operational overhead.

Cons:
- Requires a custom build step.
- You own the tiny layer on top of the base image.

Updates (what / how / cost):
- App: `inm core update` (updates app files in the volume). Cost: small CPU/RAM spikes during update.
- Image/OS/tools: `docker compose build --pull` (updates base OS + tools). Cost: rebuild time.

Create `Dockerfile.inmanage`:

```Dockerfile
FROM invoiceninja/invoiceninja-debian:${TAG:-latest}

RUN apt-get update && apt-get install -y --no-install-recommends \
    rsync zip unzip git jq curl ca-certificates mariadb-client \
  && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | bash
```

Create `docker-compose.override.yml`:

```yaml
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile.inmanage
```

Start:

```bash
docker compose up -d --build
```

INmanage is already baked in. Continue with the install steps below.

## Path 2: Sidecar (app image untouched)

Use this if you do not want to modify the app image. INmanage runs in a helper container.

Pros:
- App image stays pristine.
- Easy to disable/remove.
- Clear separation of concerns.

Cons:
- Extra container to manage.
- Slightly more compose complexity.

Updates (what / how / cost):
- App: `inm core update` from the sidecar. Cost: small CPU/RAM spikes during update.
- Sidecar image/tools: `docker compose build --pull inmanage`. Cost: rebuild time for sidecar only.
- App image: `docker compose pull app && docker compose up -d`. Cost: restart of app container.

Create `Dockerfile.inmanage` (same content as Path 1). Then create `docker-compose.override.yml`:

```yaml
services:
  inmanage:
    build:
      context: .
      dockerfile: Dockerfile.inmanage
    depends_on:
      - app
    volumes:
      - app_public:/var/www/html/public
      - app_storage:/var/www/html/storage
      - app_inmanage:/var/www/.inmanage
      - app_backup:/var/www/.backup
      - app_cache:/var/www/.cache
    entrypoint: ["/bin/sh", "-lc", "sleep infinity"]
```

Start:

```bash
docker compose up -d --build
```

INmanage is already baked in. Use the sidecar for the install steps below (replace `app` with `inmanage`).

## Path 3: Custom image (advanced)

For teams that want full control and predictable low RAM usage.

Pros:
- Tight control over packages and memory.
- Fully pinned and reproducible.

Cons:
- Highest maintenance cost.
- You must keep pace with upstream changes (Invoice Ninja releases, security updates, INmanage updates).

Guideline:
- Start from a slim Debian base.
- Install PHP-FPM + required extensions + supervisor.
- Add the INmanage tools at build time.
- Keep `public/` and `storage/` on volumes.

What “keep pace” means in practice (updates + cost):
- `inm core update` updates **Invoice Ninja app files** (inside the mounted volume). It does **not** update the container OS/packages.
- `docker compose build --pull` updates the **image OS + tools** (security patches, libs, PHP base).
- Keep INmanage up to date inside the container (`inm self update`).

Template (custom runtime image, Debian-based, aligned with the Debian VM package list):

Create `Dockerfile.custom`:

```Dockerfile
ARG PHP=8.4
FROM php:${PHP}-fpm

RUN apt-get update && apt-get install -y --no-install-recommends \
    supervisor \
    mariadb-client \
    rsync zip unzip git composer jq curl ca-certificates \
    lsb-release gnupg wget openssl xdg-utils xvfb \
    htop openssh-client libc-bin apt-transport-https \
    fonts-noto-cjk-extra fonts-wqy-microhei fonts-wqy-zenhei xfonts-wqy \
    libxcomposite1 libxdamage1 libxrandr2 libxss1 libasound2 libnss3 \
    libatk1.0-0 libatk-bridge2.0-0 libx11-xcb1 libxext6 libdrm2 libgbm1 libgbm-dev \
    libpango-1.0-0 libxshmfence1 libxshmfence-dev libgtk-3-0 libcups2 libxfixes3 libglib2.0-0 \
    libxcb1 libx11-6 libxrender1 libxcursor1 libxi6 libxtst6 \
    fonts-liberation libappindicator3-1 libdbus-1-3 \
    && if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
      mkdir -p /etc/apt/keyrings \
      && curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /etc/apt/keyrings/google.gpg \
      && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google.gpg] https://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list \
      && apt-get update \
      && apt-get install -y --no-install-recommends google-chrome-stable; \
    elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
      apt-get install -y --no-install-recommends chromium; \
    fi \
  && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | bash

COPY --from=ghcr.io/mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions \
    bcmath gd mbstring pdo pdo_mysql zip exif imagick intl pcntl soap opcache \
    apcu memcached gmp fileinfo ldap xsl readline tokenizer dom xml curl

RUN cat > /usr/local/bin/init.sh <<'EOF'
#!/bin/sh -eu
if [ "$(dpkg --print-architecture)" = "amd64" ]; then
  export SNAPPDF_CHROMIUM_PATH=/usr/bin/google-chrome-stable
elif [ "$(dpkg --print-architecture)" = "arm64" ]; then
  export SNAPPDF_CHROMIUM_PATH=/usr/bin/chromium
fi
exec "$@"
EOF
RUN chmod 0755 /usr/local/bin/init.sh

RUN cat > /usr/local/etc/php/conf.d/99-inmanage.ini <<'EOF'
memory_limit=1024M
max_execution_time=300
max_input_time=120
post_max_size=1024M
upload_max_filesize=1024M
opcache.enable=1
opcache.enable_cli=1
EOF

COPY supervisor/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

ENTRYPOINT ["/usr/local/bin/init.sh"]
CMD ["supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
```

Create `docker-compose.custom.yml`:

```yaml
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile.custom
```

Start the stack:

```bash
docker compose -f docker-compose.yml -f docker-compose.custom.yml up -d --build
```

## Install Invoice Ninja (all paths)

Choose the container:
- Path 1 & 3: `app`
- Path 2: `inmanage`

Note: Keep DB credentials in `.env` and `.env.provision` in sync (including `DB_ELEVATED_*`). `APP_URL` must match the `server_name` in `nginx/inmanage.conf`.
If you use Path 2, replace `app` with `inmanage` in the commands below.

Create the INmanage CLI config (copy/paste):

```bash
docker compose exec --user www-data app bash -lc "mkdir -p /var/www/.inmanage"
docker compose exec --user www-data app bash -lc "cat > /var/www/.inmanage/.env.inmanage <<'EOF'
INM_ENFORCED_USER=www-data
INM_BASE_DIRECTORY=/var/www
INM_INSTALLATION_DIRECTORY=./html
INM_BACKUP_DIRECTORY=./.backup
INM_CACHE_LOCAL_DIRECTORY=./.cache
INM_FORCE_READ_DB_PW=Y
EOF"
```

Create the provision file (copy/paste, then edit values):

```bash
docker compose exec --user www-data app bash -lc "cat > /var/www/.inmanage/.env.provision <<'EOF'
APP_URL=https://billing.example.test
REQUIRE_HTTPS=true
IS_DOCKER=true
IN_USER_EMAIL=admin@example.com
IN_PASSWORD=change-me
DB_HOST=db
DB_PORT=3306
DB_DATABASE=ninja
DB_USERNAME=ninja
DB_PASSWORD=change-me
DB_ELEVATED_USERNAME=root
DB_ELEVATED_PASSWORD=change-me-root
CACHE_DRIVER=redis
QUEUE_CONNECTION=redis
SESSION_DRIVER=redis
REDIS_HOST=redis
REDIS_PORT=6379
FILESYSTEM_DISK=debian_docker
MAIL_MAILER=smtp
MAIL_HOST=smtp.example.com
MAIL_PORT=587
MAIL_USERNAME=ops@example.com
MAIL_PASSWORD=change-me
MAIL_ENCRYPTION=tls
MAIL_FROM_ADDRESS=ops@example.com
MAIL_FROM_NAME=Billing
INM_NOTIFY_ENABLED=true
INM_NOTIFY_TARGETS=email
INM_NOTIFY_EMAIL_TO=ops@example.com
INM_NOTIFY_HEARTBEAT_ENABLED=true
INM_NOTIFY_HEARTBEAT_TIME=06:00
INM_NOTIFY_HEARTBEAT_LEVEL=WARN
EOF"
```

If your passwords contain `$`, backticks, or quotes, edit the file inside the container instead:

```bash
docker compose exec --user www-data app bash -lc 'nano /var/www/.inmanage/.env.provision'
```

Install Invoice Ninja via INmanage (APP_KEY is generated automatically):

```bash
docker compose exec --user www-data app bash -lc 'cd /var/www && inm core install --provision --force'
```

## After install (updates + health)

Update Invoice Ninja (app files):

```bash
docker compose exec --user www-data app bash -lc 'cd /var/www && inm core update'
```

Run health checks:

```bash
docker compose exec --user www-data app bash -lc 'cd /var/www && inm core health'
```

Do you need extra parameters? Usually **no**.
- `inm core health` works with defaults.
- If you want email notifications, set `INM_NOTIFY_*` in `.env.provision` (or in `.env.inmanage`) and install the heartbeat cron (host or sidecar).

## Operational notes

- INmanage updates modify the container filesystem. Rebuilding the app image resets app files, so rerun `inm core install` or `inm core update` after rebuilds.
- Always keep `public`, `storage`, `.inmanage`, `.backup`, and `.cache` on volumes.
- `IS_DOCKER=true` is read by Invoice Ninja (`config/ninja.php`).
