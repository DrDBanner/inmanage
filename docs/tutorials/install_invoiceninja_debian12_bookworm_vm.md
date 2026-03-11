# Installation Guide: Invoice Ninja on a Debian 12.xx VM

You'll learn how to install Invoice Ninja on a Debian 12.xx VM from scratch, including web server, database, and the INmanage CLI for fast installs, backups, and updates. It takes you about 5 to 15 minutes depending on your experience level.

This guide uses the INmanage convenience flow: a single `.env.provision` drives the install, `APP_KEY` is generated automatically, and cron/heartbeat are installed automatically when SMTP + notify settings are provided.

*If you already have a pre-configured webserver and database, you can fast forward to [Invoice Ninja installation](#9-invoice-ninja-installation). This part is independent from Debian and can be applied to any machine, where the requirements are met.*

## 1. Table of Contents

- [2. Getting Started](#2-getting-started)
  - [2.1. Invoice Ninja on Windows WSL](#21-run-invoice-ninja-on-windows-wsl)
- [3. Login via SSH](#3-login-via-ssh)
- [4. Name resolution (DNS)](#4-name-resolution-dns)
- [5. General dependencies](#5-general-dependencies)
- [6. Webserver](#6-webserver)
- [7. Database](#7-database)
- [8. Additional software](#8-additional-software)
- [9. Invoice Ninja Installation](#9-invoice-ninja-installation)
- [10. Login to your Invoice Ninja installation](#10-login-to-your-invoice-ninja-installation)

## 2. Getting Started

- Clean Debian 12.xx (bookworm) on any VM Host (wsl, utm, vmware, qemu, virtualbox, docker, you name it)
  - Create machine, attach your matching [.iso file](https://www.debian.org/releases/bookworm/debian-installer/) (amd64 most likely), launch, follow installation procedure
- During setup
  - Create root user with password
  - Create local user with password
  - Enable repository mirrors
  - Enable software packages: web server, SSH server, standard tools.

> [!NOTE]
> These VM machines do not have any local firewall rules set. So, any local service shall be accessible from the get go, as long as your virtualization host's setup aligns. This setup is not meant for public facing machines.

### 2.1 Run Invoice Ninja on Windows WSL

#### Optional Tutorial

WSL (Windows Subsystem for Linux) allows you to run a Linux environment directly on Windows 10 and above, making it easy to set up and manage Linux-based applications without leaving your Windows system. If you're on Windows, WSL provides a convenient way to run Invoice Ninja in a VM with minimal setup. Take a moment to get familiar with WSL to streamline your installation process.

WSL & Debian VM Setup on Windows (steps 2.1.1–2.1.7).

### 2.1.1. Enable WSL and Virtual Machine Platform

Open a terminal as **Administrator** (Press `[WIN]`, type `Terminal`, right click -> select `run as Administrator`.) and enable WSL:

*This enables or switches to WSL1. If you already use WSL you can skip it and just install the Debian image.*
```powershell
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
```

Restart your computer.

### 2.1.2. Install Debian

After a successful restart of your computer open a Terminal as your current user and paste these commands.

*If you already use WSL2 skip the `--set-default-version` part.*

```powershell
wsl --set-default-version 1
wsl --install Debian

# Enter a Username and a Password when prompted.
# Username shall not have empty spaces.
```

> ## NOTE
>
> *This WSL VM automatically has the IP-Address of your local Windows and your Firewall may need to be taught to accept connections on port 443 in order to serve the https:// webinterface.*
>
> And in order to disable the VM get crawled by Windows Defender Antimalware Service.
> Paste this to the terminal as **Administrator** only if you use Microsoft Defender:
> ```text
> New-NetFirewallRule -DisplayName "Allow HTTPS Inbound" -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow
>
> Add-MpPreference -ExclusionPath "$env:LOCALAPPDATA\Packages\TheDebianProject.DebianGNULinux_*\LocalState"
> ```

### 2.1.4. Launch Debian Terminal

Open Terminal as your current user

```text
wsl -d Debian
```
This command logs you into the Debian VM.

### 2.1.6. Update Debian

Update package lists and upgrade packages:
```bash
sudo apt update && sudo apt upgrade -y

# Install some dependencies NOW!

sudo apt install -y git curl wget unzip zip htop openssh-client libc-bin openssl
```

### 2.1.8. Scheduler Task – Autostart and Shutdown the VM on Windows Start and Shutdown

To automatically start and stop your WSL Debian VM with Windows:

**Autostart on Windows boot:**
1. Press `[WIN]` and type `Task Scheduler`, then open it.
1. Click **Create Task**.
1. Under **General**, name it (e.g., `Start WSL Debian`).
1. Go to **Triggers** tab, click **New**, set **Begin the task** to `At startup`.
1. Go to **Actions** tab, click **New**, set **Action** to `Start a program`.
1. In **Program/script**, enter:

    ```text
    wsl -d Debian
    ```
1. Click **OK** to save.

**Shutdown on Windows shutdown:**
1. Create another task as above, but in **Triggers** set **Begin the task** to `On shutdown`.
1. In **Actions**, use:

    ```text
    wsl --shutdown
    ```
1. Click **OK**.

This ensures your Debian VM starts with Windows and shuts down cleanly when Windows powers off.

### 2.1.9. Ready to Continue

You can now proceed with the tutorial – jump to [4. Name resolution (DNS)](#4-name-resolution-dns) and right after that skip to [6. Webserver](#6-webserver) since sudo is already available on the WSL Debian VM. All further commands should be run within your Debian terminal as your created VM's user.

*You can login to the WSL VM at any time from a new terminal by executing `wsl -d Debian`*

### 2.1.10. WSL 1 Issues

#### php-fpm via socket

On WSL1 I was not able to get php-fpm properly working. In order to fix that you need to switch to a TCP based listener. Fortunately I created a script for that. Note: You need that with WSL1 only.

*Copy and paste the following into your terminal to create the patch script. Run it as root after setting up the webserver and database, but before installing Invoice Ninja with INmanage.*

```bash
cat > patch_phpfpm_socket_wsl1.sh <<'EOF'
#!/bin/bash

set -e

NGINX_SITES="/etc/nginx/sites-available"

for dir in /etc/php/*/fpm; do
  [ -d "$dir" ] || continue

  PHPVER=$(basename "$(dirname "$dir")")
  PHP_POOL_CONF="$dir/pool.d/www.conf"
  PHP_MAIN_CONF="$dir/php-fpm.conf"

  echo "Patching PHP $PHPVER – pool config: $PHP_POOL_CONF"

  if ! grep -q "^listen = 127.0.0.1:9000" "$PHP_POOL_CONF"; then
    sudo sed -i \
      -e '/^listen\s*=/{/127.0.0.1:9000/!s/^/;/}' \
      -e '/^listen\s*=/{/127.0.0.1:9000/!a\
listen = 127.0.0.1:9000
}' \
      -e '/^listen\.owner\s*=/{s/^/;/}' \
      -e '/^listen\.group\s*=/{s/^/;/}' \
      -e '/^listen\.mode\s*=/{s/^/;/}' \
      "$PHP_POOL_CONF"
  else
    echo "  → Already using 127.0.0.1:9000"
  fi

  echo "Patching PHP $PHPVER – main config: $PHP_MAIN_CONF (log_level)"
  if grep -q "^log_level\s*=\s*warning" "$PHP_MAIN_CONF" && ! grep -q "^log_level\s*=\s*alert" "$PHP_MAIN_CONF"; then
    sudo sed -i \
      -e '/^log_level\s*=\s*warning/{s/^/;/;a\
log_level = alert
}' \
      "$PHP_MAIN_CONF"
  else
    echo "  → log_level already set or patched"
  fi
done

echo "Searching nginx sites in $NGINX_SITES for fastcgi_pass unix:"
for file in "$NGINX_SITES"/*; do
  [ -f "$file" ] || continue

  if grep -q "^\s*fastcgi_pass unix:" "$file"; then
    echo "Patching: $file"

    if ! grep -q "fastcgi_pass 127.0.0.1:9000;" "$file"; then
      sudo sed -i \
        -e '/^\s*fastcgi_pass unix:/s/^/#/' \
        -e '/^\s*#\s*fastcgi_pass unix:/a\
    fastcgi_pass 127.0.0.1:9000;
' "$file"
    else
      echo "  → 127.0.0.1:9000 already present"
    fi
  fi
done

echo "Done. Restart affected services manually:"
for dir in /etc/php/*/fpm; do
  [ -d "$dir" ] || continue
  PHPVER=$(basename "$(dirname "$dir")")
  echo "  sudo service php${PHPVER}-fpm restart"
done
echo "  sudo service nginx reload"
EOF

chmod +x patch_phpfpm_socket_wsl1.sh
```

#### SNAPPDF on WSL1

*Snappdf seems not to work on WSL 1 VMs.*
Set the variable in `.env.provision` before running the provisioned install:
```text
PDF_GENERATOR=hosted_ninja
```



## 3. Login via SSH

After installing Debian 12 Bookworm, log into the VM via SSH Terminal. Using SSH from your local terminal makes it easier to copy and paste commands and ensures a hassle-free experience.

If you do not know your VM's IP address yet, you'll need to login via the VM's Application window once, in order to gather the IP. So, login as root. Then type:

```bash
ip addr
```
and press [ENTER].

Somewhere around the `inet` lines you'll see your local IP address (e.g. like: 192.168.64.9) which you'll need to login via SSH.

> [!NOTE]
> *If you are faced with a graphical user interface you'll need to open a terminal window within the VM in order to gather the IP information. You can obtain from below how that's done. Keep in mind to switch to a new terminal on your local machine once you obtained the IP address.*

### 3.1. Open Terminal

The terminal can be opened like the following examples.

### 3.1. Open a terminal

#### 3.1.1. MacOS

Press [⌘ CMD] + [SPACE] -> Type `Terminal` -> Press [ENTER]

#### 3.1.2. Linux

Press [CTRL] + [ALT] + [T]

#### 3.1.3. Windows 11

Press [⌘ WIN] -> Type `Terminal` -> Press [ENTER]

*On older Windows machines you'll need an additional application like [Putty](https://www.putty.org).*

### 3.2. Login

Replace `user` and IP `192.168.64.9` with your corresponding data and execute the following command in your terminal.
```bash
ssh user@192.168.64.9
```

*In the next step you'll learn how to map a domain name to the VM. Once done you'll be able to access your VM via SSH like this as well:*
```bash
ssh user@billing.debian12vm.local
```

**This depends on your virtualization software. Consult its documentation or social resources if you can't reach/access the VM from your local terminal. Firewalls and network translation settings are the common subjects here.**

## 4. Name resolution (DNS)

To access your webserver via a fully qualified domain name (FQDN) within the VM machine, **your computer** must map the name to the corresponding IP address of the VM. Without a local DNS server, you can do this locally using the `hosts` file on your machine **–not the VM's**.

On some virtualization platforms, *.local domains might not resolve correctly without additional configuration (e.g. Avahi/mDNS). Consider using a different domain name instead.

### 4.1. Open hosts file

#### 4.1.1. MacOS

*Open a new Terminal and paste:*
```bash
sudo nano /etc/hosts
```

#### 4.1.2. Linux

*Open a new Terminal and paste:*
```bash
sudo nano /etc/hosts
```

#### 4.1.3. Windows 11

*Open a new Terminal as Administrator:*

*Press [⌘ WIN] -> Type `Terminal` -> Right-Mouseclick on `Terminal` -> select `run as Administrator` and paste:*
```powershell
notepad $env:WINDIR\System32\drivers\etc\hosts
```

### 4.2. Edit hosts file

Append at the bottom of the hosts file this line and be sure to set your VM's IP to the correct value:
```bash
192.168.64.9 billing.debian12vm.local
```
Save the changed file.

*From now on you should be able to `Ping` your VM with:*
```bash
ping billing.debian12vm.local
```
*You can set any Domain name you want, but you'll need to adapt all the later occurances of this domain name in the upcoming configurations. So, keeping as is, may save you some valuable time.*

### 4.3. Public Servers / DNS

If your VM is publicly hosted, DNS and certificate settings depend on how your domain is configured. This could be managed by your hosting provider or a third-party DNS service. The same applies if you're using a local DNS server within your LAN.

## 5. General dependencies

On a clean Debian 12.xx some additional tools may be missing. Especially, if you install from a factory ISO file. You'll add them. But before you start, disable the cdrom repository for software updates. Assuming you are logged in as the local user, copy and paste the following code to do so:

```bash
su -
sed -i '/^deb cdrom:/ s/^/#/' /etc/apt/sources.list
```

*You switch over to root with `su -` (The dash ensures the correct root environment is loaded on Debian.)*

### 5.1. Sudo installation and activation

Update the apt database and install the package sudo. Afterwards you add the user `user` to the group sudo in order to allow them to execute sudo commands.

*Keep in mind to replace `user` with your corresponding username.*

```bash

## reminder: You need to be root for this. Like this: su -
## if not, You may face usermod command not found errors.

apt update
apt install sudo
usermod -aG sudo user
su - user
```

*If usermod fails it most likely does because you didn't use `su -` with dash to switch to the root user, so, keep in mind. Running `su - user` means to open a new shell session as user `user` to activate sudo for the user and switch context.*

## 6. Webserver

If you wish to have a different domain than `billing.debian12vm.local` you need to adapt the code and make sure not to miss one line. Keep in mind you need to change your DNS mapping from [4. Name Resolution](#4-name-resolution-dns) accordingly.

### 6.1. Certificate installation

In order to ensure `https://` connections with the webserver you need a certificate to do so. Paste this code to create a self-signed certificate within the VM:

```bash
sudo apt install openssl && sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
-keyout /etc/ssl/private/billing.debian12vm.local.key \
-out /etc/ssl/certs/billing.debian12vm.local.crt \
-subj "/C=US/ST=State/L=City/O=Local/OU=Dev/CN=billing.debian12vm.local"
```

*This is mandatory and at the same time it is only a valid method for local VM's. If you are running on a publically accessible VM your hoster has a recommended procedure to attach valid certificates to your domain. You may need to trust this certificate manually in your OS/browser for a seamless experience.*

### 6.2. nginx

Install the webserver with this command. Any possible apache installation gets removed.:
```bash
sudo apt remove apache2 -y
sudo apt install nginx -y
```

Then copy and paste this code to create the webserver destination path, a configuration file, test it, and activate it in one batch:

```bash
# Create nginx configuration

sudo tee /etc/nginx/sites-available/billing.debian12vm.local > /dev/null <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name billing.debian12vm.local;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name billing.debian12vm.local;

    ssl_certificate /etc/ssl/certs/billing.debian12vm.local.crt;
    ssl_certificate_key /etc/ssl/private/billing.debian12vm.local.key;

    root /var/www/billing.debian12vm.local/invoiceninja/public/;
    index index.php index.html index.htm;

    charset utf-8;
    client_max_body_size 1024M;

    access_log  /var/log/nginx/billing.debian12vm.local.access.log;
    error_log   /var/log/nginx/billing.debian12vm.local.error.log;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 64k;
        fastcgi_buffers 8 64k;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }
    location ~ /\.ht { deny all; }

    # Caching for static files
    location ~* \.(jpg|jpeg|gif|png|webp|css|js|ico|woff2?|ttf|svg|eot|otf)$ {
        expires 30d;
        add_header Cache-Control "public";
    }

    # Gzip Compression
    gzip on;
    gzip_disable "msie6";
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/javascript
        application/x-javascript
        application/json
        application/xml
        application/xml+rss
        font/ttf
        font/otf
        image/svg+xml;

    # Connection performance
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
}
EOF

# Create target directory and change owner
sudo mkdir -p /var/www/billing.debian12vm.local/invoiceninja/public/
sudo chown www-data:www-data -R /var/www/billing.debian12vm.local

# Make configuration available; check it and enable webserver
sudo ln -sf /etc/nginx/sites-available/billing.debian12vm.local /etc/nginx/sites-enabled/

```

---

### 6.3. Scripting language

#### 6.3.1. PHP 8.4


Paste this code to add the php8.4 repository to your VM and install php in one batch:

```bash
sudo apt install lsb-release ca-certificates curl apt-transport-https gnupg -y
curl -fsSL https://packages.sury.org/php/apt.gpg | sudo gpg --dearmor -o /usr/share/keyrings/deb.sury.org-php.gpg
echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/php.list
sudo apt update
sudo apt install php8.4-cli php8.4-fpm php8.4-mysql php8.4-xml php8.4-mbstring php8.4-bcmath php8.4-curl php8.4-zip php8.4-gd php8.4-intl php8.4-soap php8.4-opcache php8.4-apcu php8.4-memcached php8.4-imagick php8.4-gmp php8.4-fileinfo php8.4-pdo php8.4-ldap php8.4-xsl php8.4-common php8.4-readline php8.4-tokenizer php8.4-dom -y
```

Paste this code to extend the php.ini configuration to fpm and cli in one batch:

```bash
sudo tee -a /etc/php/8.4/cli/php.ini /etc/php/8.4/fpm/php.ini > /dev/null <<'EOF'
apc.enable_cli=1
opcache.enable=1
opcache.enable_cli=1
opcache.interned_strings_buffer=30
opcache.max_accelerated_files=10000
opcache.memory_consumption=512
opcache.save_comments=1
opcache.validate_timestamps=1
opcache.revalidate_freq=0
opcache.enable_file_override=1
opcache.file_cache=/tmp/php-opcache
realpath_cache_size=4096k
realpath_cache_ttl=600
zend.assertions=1
display_errors=Off
display_startup_errors=Off
log_errors=On
error_log=/var/log/php_errors.log
error_reporting=E_ALL & ~E_DEPRECATED & ~E_STRICT
memory_limit=1024M
max_execution_time=300
max_input_time=120
post_max_size=1024M
upload_max_filesize=1024M
cgi.fix_pathinfo=0
date.timezone = Europe/Berlin       ;Adapt to your location
EOF
```

Now test and start webserver and install autostart for php fpm and webserver

```bash
sudo nginx -t

if systemctl is-system-running --quiet 2>/dev/null; then
   sudo systemctl enable php8.4-fpm
   sudo systemctl start php8.4-fpm
   sudo systemctl enable nginx
   sudo systemctl start nginx
else
  sudo /etc/init.d/php8.4-fpm start
  sudo service nginx start
  grep -q 'php8.4-fpm' ~/.bashrc || echo "pgrep php-fpm8.4 >/dev/null || sudo /etc/init.d/php8.4-fpm start" >> ~/.bashrc
  grep -q 'pgrep nginx' ~/.bashrc || echo 'pgrep nginx >/dev/null || sudo service nginx start' >> ~/.bashrc
fi

## If any error occour, fix them and rerun this code block.
```

## 7. Database

### 7.1. mariadb


This code installs the database, enables the service, and provides the user `root` user with a standard password.

```bash
sudo apt install mariadb-server mariadb-client -y

if systemctl is-system-running --quiet 2>/dev/null; then
  sudo systemctl enable mariadb
  sudo systemctl start mariadb
else
  sudo service mariadb start
  grep -q 'pgrep -x mysqld' ~/.bashrc || echo 'pgrep -x mysqld >/dev/null || sudo service mariadb start' >> ~/.bashrc
fi

sleep 5

# Set a password for MariaDB root user (change YOUR_PASSWORD3556757 if neccessary!)
sudo mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('YOUR_PASSWORD3556757');
FLUSH PRIVILEGES;
EOF
```

You may optionally run `mysql_secure_installation` to improve database security, especially on public-facing servers.


## 8. Additional software

Paste this to install other **mandatory** software:

```bash
sudo apt install unzip zip rsync git composer jq libxcomposite1 libxdamage1 libxrandr2 libxss1 libasound2 libnss3 libatk1.0-0 libatk-bridge2.0-0 libx11-xcb1 libxext6 libdrm2 libgbm1 libgbm-dev libpango-1.0-0 libxshmfence1 libxshmfence-dev libgtk-3-0 libcups2 libxfixes3 libglib2.0-0 libxcb1 libx11-6 libxrender1 libxcursor1 libxi6 libxtst6 fonts-liberation libappindicator3-1 libdbus-1-3 lsb-release xdg-utils wget curl ca-certificates gnupg xvfb -y
```

## 9. Invoice Ninja Installation

### 9.1. Install INmanage CLI

You already set up the web server and database. Now install the INmanage CLI:

```bash
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | sudo bash -s -- --mode system
```

The installer creates global symlinks (`inm`, `inmanage`) in `/usr/local/bin`.

Pick the user that should own and run the app files. Common values are `www-data`, `nginx`, `apache`, or `httpd`. On shared hosting, use your login user (for example `username` or `web234355`). The commands below use `www-data`.

```bash
cd /var/www/billing.debian12vm.local
sudo -u www-data inm                       # create CLI config
```

When prompted, accept the defaults and set **FORCE_READ_DB_PW** to `Y` (read DB password from the app `.env`).

<a href="https://github.com/user-attachments/assets/342ca8a9-4ab5-4d16-ba56-43acd9c5f6ec" target="_blank">
  <img src="https://github.com/user-attachments/assets/777f1217-1d7d-4c65-bb85-db6d36b57644" alt="Install CLI Config" width="100%">
</a>

### 9.2. Provisioned install (single file)

Run the installer and pick **provisioned** when asked. If no provision file exists, it will offer to create one and open it in your editor. After you save and exit, the install continues automatically.

```bash
sudo -u www-data inm core install --force
```

Notes:
- We use `--force` because the nginx setup already created the app directory. This acknowledges the destructive nature of a provisioned install.
- `APP_KEY` is generated automatically; do not set it in `.env.provision`.
- You can put any `INM_*` keys into `.env.provision`. They are copied into `.inmanage/.env.inmanage` and stripped from the app `.env`. See the full CLI config reference in the main docs: <../index.md#cli-config-reference-envinmanage>
- A health check runs automatically during installation.

Minimal `.env.provision` example:

```env
APP_URL=https://billing.debian12vm.local
DB_HOST=localhost
DB_PORT=3306
DB_DATABASE=ninja
DB_USERNAME=ninja
DB_PASSWORD=change-me

DB_ELEVATED_USERNAME=root
DB_ELEVATED_PASSWORD=YOUR_PASSWORD3556757

MAIL_MAILER=smtp
MAIL_HOST=smtp.example.com
MAIL_PORT=587
MAIL_USERNAME=ops@example.com
MAIL_PASSWORD=change-me
MAIL_ENCRYPTION=tls
MAIL_FROM_ADDRESS=ops@example.com
MAIL_FROM_NAME=Billing

INM_NOTIFY_ENABLE=true
INM_NOTIFY_TARGETS_LIST=email
INM_NOTIFY_EMAIL_TO_LIST=ops@example.com
INM_NOTIFY_HEARTBEAT_ENABLE=true
INM_NOTIFY_HEARTBEAT_LEVEL=WARN
INM_NOTIFY_HEARTBEAT_TIME=06:00
```

If your MariaDB root user uses socket auth, set `DB_ELEVATED_PASSWORD=auth_socket` instead of a password and run the install with sudo.

When you include valid `MAIL_*` SMTP settings and the minimum notification keys (`INM_NOTIFY_ENABLE`, `INM_NOTIFY_TARGETS_LIST`, `INM_NOTIFY_HEARTBEAT_ENABLE`, `INM_NOTIFY_HEARTBEAT_LEVEL`), the installer auto-installs the heartbeat cron job and sends a test mail. Otherwise, it installs only the essential cron jobs (artisan + backup).

<a href="https://github.com/user-attachments/assets/999051b4-ad27-46f6-b75d-10975c56d3ba" target="_blank">
  <img src="https://github.com/user-attachments/assets/dcaa1fc8-727b-4cae-b13f-3818763a76e2" alt="Install IN" width="100%">
</a>

After you confirm the install, you should see a "Setup Complete!" summary with the app URL and default admin credentials. When you are satisfied, delete the provision file because it contains secrets:

```bash
sudo -u www-data rm /var/www/billing.debian12vm.local/.inmanage/.env.provision
```

If you want to adjust the provision file later and re-run, reopen it with:

```bash
sudo -u www-data nano /var/www/billing.debian12vm.local/.inmanage/.env.provision
```

If you chose the wrong enforced user during first run, fix it like this:

```bash
sudo inm env set cli INM_EXEC_USER="www-data"
sudo inm core health --fix-permissions --override-enforced-user
```

### 9.3. First Invoice Ninja Backup

Run your first backup:

```bash
sudo -u www-data inm core backup
```

### 9.4. Health check

Run a quick health check:

```bash
sudo -u www-data inm core health
```

Use `--compact` if you prefer a short section summary instead of the full table output.


## 10. Login to your Invoice Ninja installation

Since everything is working as expected it's time to login:

Open your local browser at <https://billing.debian12vm.local> to access the application. Most likely your browser will complain about the certificate –that's pretty normal, since you self-signed the certificate. You'll need to look for a link that says `Extended` or `Continue to billing.debian12vm.local (insecure)` and click that once. Your browser should remember your choice next time you open this page.

**Username:** <admin@admin.com>

**Password:** admin

Have fun. Don't forget to star and bookmark the [INmanage repo](https://github.com/DrDBanner/inmanage/).
