# Ansible: Full Environment (Debian/Ubuntu)

This recipe installs the full stack for a VM or bare-metal host:
UNTESTED

- Base packages
- Nginx + PHP-FPM
- MariaDB
- Nginx vhost + TLS (self-signed for local/dev)
- INmanage + provisioned Invoice Ninja install

Back to the main docs:
[docs/index.md](./../index.md#containers--vms-onboarding-invoice-ninja-and-inmanage).

---

## Snippet A - Base stack (nginx, PHP, MariaDB, vhost)

Use this when you need the full system stack. It sets up nginx, PHP, MariaDB, and the vhost.

```yaml
- hosts: invoiceninja_vms
  become: true
  vars:
    domain: billing.example.com
    base_dir: /var/www/billing.example.com
    install_dir: invoiceninja
    web_user: www-data
    php_version: "8.4"
    db_root_password: change-me-root # Use "auth_socket" to keep socket auth (no password).
  tasks:
    - name: Base packages
      apt:
        name:
          - curl
          - rsync
          - zip
          - unzip
          - git
          - jq
          - wget
          - openssl
          - lsb-release
          - ca-certificates
          - gnupg
          - apt-transport-https
          - python3-pymysql
        state: present
        update_cache: true

    - name: Snappdf dependencies (Debian/Ubuntu)
      apt:
        name:
          - libxcomposite1
          - libxdamage1
          - libxrandr2
          - libxss1
          - libasound2
          - libnss3
          - libatk1.0-0
          - libatk-bridge2.0-0
          - libx11-xcb1
          - libxext6
          - libdrm2
          - libgbm1
          - libpango-1.0-0
          - libxshmfence1
          - libgtk-3-0
          - libcups2
          - libxfixes3
          - libglib2.0-0
          - libxcb1
          - libx11-6
          - libxrender1
          - libxcursor1
          - libxi6
          - libxtst6
          - fonts-liberation
          - libappindicator3-1
          - libdbus-1-3
          - xdg-utils
          - xvfb
        state: present
        update_cache: true

    - name: Remove Apache (if present)
      apt:
        name: apache2
        state: absent
        purge: true
      ignore_errors: true

    - name: Install nginx
      apt:
        name:
          - nginx
        state: present

    - name: Add Sury PHP repo
      shell: |
        curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/deb.sury.org-php.gpg
        echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
      args:
        creates: /etc/apt/sources.list.d/php.list

    - name: Install PHP and extensions
      apt:
        name:
          - "php{{ php_version }}-cli"
          - "php{{ php_version }}-fpm"
          - "php{{ php_version }}-mysql"
          - "php{{ php_version }}-xml"
          - "php{{ php_version }}-mbstring"
          - "php{{ php_version }}-bcmath"
          - "php{{ php_version }}-curl"
          - "php{{ php_version }}-zip"
          - "php{{ php_version }}-gd"
          - "php{{ php_version }}-intl"
          - "php{{ php_version }}-soap"
          - "php{{ php_version }}-opcache"
          - "php{{ php_version }}-imagick"
          - "php{{ php_version }}-gmp"
          - "php{{ php_version }}-fileinfo"
        state: present
        update_cache: true

    - name: Tune PHP (CLI + FPM)
      blockinfile:
        path: "/etc/php/{{ php_version }}/{{ item }}/php.ini"
        marker: "; {mark} INmanage"
        block: |
          memory_limit=1024M
          max_execution_time=300
          max_input_time=120
          post_max_size=1024M
          upload_max_filesize=1024M
          opcache.enable=1
          opcache.enable_cli=1
      loop:
        - cli
        - fpm

    - name: Install MariaDB
      apt:
        name:
          - mariadb-server
          - mariadb-client
        state: present

    - name: Ensure services are enabled
      service:
        name: "{{ item }}"
        state: started
        enabled: true
      loop:
        - nginx
        - "php{{ php_version }}-fpm"
        - mariadb

    - name: Set MariaDB root password (optional)
      mysql_user:
        name: root
        host: localhost
        password: "{{ db_root_password }}"
        login_unix_socket: /run/mysqld/mysqld.sock
        check_implicit_admin: true
        priv: "*.*:ALL,GRANT"
      when: db_root_password not in ["", "auth_socket"]

    - name: Self-signed TLS cert (local dev)
      command: >
        openssl req -x509 -nodes -days 365 -newkey rsa:2048
        -keyout /etc/ssl/private/{{ domain }}.key
        -out /etc/ssl/certs/{{ domain }}.crt
        -subj "/C=US/ST=State/L=City/O=Local/OU=Dev/CN={{ domain }}"
      args:
        creates: "/etc/ssl/certs/{{ domain }}.crt"

    - name: Nginx vhost
      copy:
        dest: "/etc/nginx/sites-available/{{ domain }}"
        content: |
          server {
              listen 80;
              listen [::]:80;
              server_name {{ domain }};
              return 301 https://$host$request_uri;
          }

          server {
              listen 443 ssl http2;
              listen [::]:443 ssl http2;
              server_name {{ domain }};

              ssl_certificate /etc/ssl/certs/{{ domain }}.crt;
              ssl_certificate_key /etc/ssl/private/{{ domain }}.key;

              root {{ base_dir }}/{{ install_dir }}/public;
              index index.php index.html index.htm;

              charset utf-8;
              client_max_body_size 1024M;

              location / {
                  try_files $uri $uri/ /index.php?$query_string;
              }

              location ~ \.php$ {
                  include snippets/fastcgi-php.conf;
                  fastcgi_pass unix:/run/php/php{{ php_version }}-fpm.sock;
                  fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                  fastcgi_intercept_errors off;
              }

              location ~ /\.ht { deny all; }
          }

    - name: Enable nginx vhost
      file:
        src: "/etc/nginx/sites-available/{{ domain }}"
        dest: "/etc/nginx/sites-enabled/{{ domain }}"
        state: link

    - name: Create base directory
      file:
        path: "{{ base_dir }}"
        state: directory
        owner: "{{ web_user }}"
        group: "{{ web_user }}"
        mode: "2750"

    - name: Reload nginx
      service:
        name: nginx
        state: reloaded
```

---

## Snippet B - INmanage + provisioned install

Use this after Snippet A (or any time your base stack already exists).

```yaml
- hosts: invoiceninja_vms
  become: true
  vars:
    domain: billing.example.com
    base_dir: /var/www/billing.example.com
    install_dir: invoiceninja
    web_user: www-data
    db_root_password: change-me-root # Use "auth_socket" to keep socket auth (no password).
    db_name: ninja
    db_user: ninja
    db_password: change-me
    app_url: "https://{{ domain }}"
    notify_email: ops@example.com
  tasks:
    - name: Ensure CLI config directory exists
      file:
        path: "{{ base_dir }}/.inmanage"
        state: directory
        owner: "{{ web_user }}"
        group: "{{ web_user }}"
        mode: "0750"

    - name: Ensure backup directory exists
      file:
        path: "{{ base_dir }}/.backup"
        state: directory
        owner: "{{ web_user }}"
        group: "{{ web_user }}"
        mode: "2750"

    - name: Install INmanage (system)
      shell: curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | bash
      args:
        creates: /usr/local/share/inmanage/inmanage.sh

    - name: Write CLI config
      copy:
        dest: "{{ base_dir }}/.inmanage/.env.inmanage"
        owner: "{{ web_user }}"
        group: "{{ web_user }}"
        mode: "0600"
        content: |
          INM_EXEC_USER={{ web_user }}
          INM_PATH_BASE_DIR={{ base_dir }}/
          INM_PATH_APP_DIR=./{{ install_dir }}
          INM_BACKUP_DIR=./.backup
          INM_DB_FORCE_READ_PW_ENABLE=Y
          INM_NOTIFY_ENABLE=true
          INM_NOTIFY_TARGETS_LIST=email
          INM_NOTIFY_EMAIL_TO_LIST={{ notify_email }}
          INM_NOTIFY_HEARTBEAT_ENABLE=true
          INM_NOTIFY_HEARTBEAT_TIME=06:00
          INM_NOTIFY_HEARTBEAT_LEVEL=WARN

    - name: Write provision file (Invoice Ninja + INmanage)
      copy:
        dest: "{{ base_dir }}/.inmanage/.env.provision"
        owner: "{{ web_user }}"
        group: "{{ web_user }}"
        mode: "0600"
        content: |
          APP_URL={{ app_url }}
          DB_HOST=localhost
          DB_PORT=3306
          DB_DATABASE={{ db_name }}
          DB_USERNAME={{ db_user }}
          DB_PASSWORD={{ db_password }}
          DB_ELEVATED_USERNAME=root
          DB_ELEVATED_PASSWORD={{ db_root_password }}
          MAIL_MAILER=smtp
          MAIL_HOST=smtp.example.com
          MAIL_PORT=587
          MAIL_USERNAME={{ notify_email }}
          MAIL_PASSWORD=change-me
          MAIL_ENCRYPTION=tls
          MAIL_FROM_ADDRESS={{ notify_email }}
          MAIL_FROM_NAME=Billing
          INM_NOTIFY_ENABLE=true
          INM_NOTIFY_TARGETS_LIST=email
          INM_NOTIFY_EMAIL_TO_LIST={{ notify_email }}
          INM_NOTIFY_HEARTBEAT_ENABLE=true
          INM_NOTIFY_HEARTBEAT_TIME=06:00
          INM_NOTIFY_HEARTBEAT_LEVEL=WARN

    - name: Install Invoice Ninja (provisioned)
      become_user: "{{ web_user }}"
      shell: /usr/local/bin/inm core install --provision --force
```
