# Installation Guide: Invoice Ninja on a Debian 12.xx VM

You'll learn how to install Invoice Ninja on a Debian 12.xx VM from scratch including everything and extended with a helper script for fast install, backups, and updates. It takes you about 5 to 15 minutes depending on your experience level.

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

*Copy and paste the following into your terminal to create the patch script. Run it as root after setting up the webserver and database, but before installing Invoice Ninja with inmanage.*

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

*Snappdf seems not to work on WSL 1 VM's*
So, leave the variable in the .env file like this when you configure the provision file:
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
sudo apt install unzip git composer jq libxcomposite1 libxdamage1 libxrandr2 libxss1 libasound2 libnss3 libatk1.0-0 libatk-bridge2.0-0 libx11-xcb1 libxext6 libdrm2 libgbm1 libpango-1.0-0 libxshmfence1 libgtk-3-0 libcups2 libxfixes3 libglib2.0-0 libxcb1 libx11-6 libxrender1 libxcursor1 libxi6 libxtst6 fonts-liberation libappindicator3-1 libdbus-1-3 lsb-release xdg-utils wget curl ca-certificates gnupg xvfb -y
```

## 9. Invoice Ninja Installation

### 9.1. Inmanage script installation

Previously you have successfully setup a webserver, a database, and installed some mandatory additional packages. Now the fun begins. Install the Inmanage CLI and bootstrap the project config + provision template:

```bash
curl -fsSL https://raw.githubusercontent.com/DrDBanner/inmanage/main/install_inmanage.sh | sudo bash -s -- --mode system

cd /var/www/billing.debian12vm.local
sudo -u www-data inmanage core provision spawn
```

The CLI setup prompts for the basic config (base directory, install dir, backup settings, etc.). You can go with the defaults by pressing [enter] each, except for `Include DB password in backup`. You answer with `Y` instead.

```text
    _____   __                                       __
   /  _/ | / /___ ___  ____ _____  ____ _____ ____  / /
   / //  |/ / __ `__ \/ __ `/ __ \/ __ `/ __ `/ _ \/ /
 _/ // /|  / / / / / / /_/ / / / / /_/ / /_/ /  __/_/
/___/_/ |_/_/ /_/ /_/\__,_/_/ /_/\__,_/\__, /\___(_)
                                      /____/
INVOICE NINJA - MANAGEMENT SCRIPT



2025-07-16 13:32:31 [NOTE] [ENV] Project config file not found.
2025-07-16 13:32:31 [INFO] [COC] Creating configuration in: /var/www/billing.debian12vm.local/.inmanage/.env.inmanage

========== Install Wizard ==========

2025-07-16 13:32:31 Just press [ENTER] to accept default values.

BASE_DIRECTORY: This will contain your Invoice Ninja app directory (next step). It's not webserver's docroot. Define your desired location or keep.
[/var/www/billing.debian12vm.local/] >

INSTALLATION_DIRECTORY: Invoice Ninja App directory. The web-server usually serves from <INSTALLATION_DIRECTORY>/public. Define your desired location or keep.
[./invoiceninja] >

KEEP_BACKUPS: Backup retention? Set to 2 to keep 2 backups in the past at a time. Ensure enough disk space and keep the backup frequency in mind.
[2] >

FORCE_READ_DB_PW: Include DB password in CLI? (Y): Convenient, but may expose the password to other server users during runtime. (N): Assumes a secure .my.cnf file with credentials to avoid exposure.
[N] > Y

ENFORCED_USER: Correct setting helps to mitigate permission issues. Usually the webserver user. On shared hosting often your current user. If current is true, you can leave this empty.
[www-data] >

GitHub API credentials may be required on shared hosting. Use the format username:password or token:x-oauth. If provided, all curl commands will use these credentials;
[] >

2025-07-16 13:33:40 [OK] .inmanage/.env.inmanage has been created and configured.
 [INFO] [COC] Downloading .env.example for provisioning
```

Done. The CLI is installed and the project config is created.

#### 9.1.1. CLI is ready

The installer already created global symlinks (`inmanage`, `inm`) in `/usr/local/bin`.

### 9.2. Inmanage script provision

`core provision spawn` opens your editor automatically so you can edit the generated provision template right away. If you need to reopen it later:

```bash
sudo -u www-data nano .env.provision
```

Full [Provisioning Readme](https://github.com/DrDBanner/inmanage/#provisioned-invoice-ninja-installation)

Mandatory settings to adjust:

```env
APP_URL=https://billing.debian12vm.local
DB_PASSWORD=yourNewInvoiceninjaDBPassword
DB_ELEVATED_USERNAME=root
DB_ELEVATED_PASSWORD=YOUR_PASSWORD3556757
PDF_GENERATOR=snappdf
PDF_PAGE_NUMBER_X=0
PDF_PAGE_NUMBER_Y=-6
MAIL_HOST=smtp.yourmailhost.com
MAIL_PORT=587
MAIL_USERNAME="your_email_address@yourmailhost.com"
MAIL_PASSWORD="your_password_dont_forget_the_quotes!"
MAIL_ENCRYPTION=tls
MAIL_FROM_ADDRESS="your_email_address@yourmailhost.com"
MAIL_FROM_NAME="Full Name With Double Quotes"
```

Optionally, you can set any additional configuration that's desired. You can find all options in the [Invoice Ninja Manual -.env variables](https://invoiceninja.github.io/en/env-variables/). Use [CTRL]+[X] to save an exit the `nano` editor once you are satisfied with your settings.

### 9.3. Install Invoice Ninja

Previously you have installed the `inmanage` script and you have prepopulated a configuration for provisioning. Now it's time to start the installation procedure:

```bash
inmanage core install --provision --force
```

The caution message is correct (*The path was already created to circumvent a webserver error.*) and you can easily enter `yes` in order to carry on.

```text
   _____   __                                       __
   /  _/ | / /___ ___  ____ _____  ____ _____ ____  / /
   / //  |/ / __ `__ \/ __ `/ __ \/ __ `/ __ `/ _ \/ /
 _/ // /|  / / / / / / /_/ / / / / /_/ / /_/ /  __/_/
/___/_/ |_/_/ /_/ /_/\__,_/_/ /_/\__,_/\__, /\___(_)
                                      /____/
INVOICE NINJA - MANAGEMENT SCRIPT



2025-07-16 13:39:30 [OK] Loaded settings from .inmanage/.env.inmanage.
2025-07-16 13:39:30 [OK] Provision file loaded. Installation starts now.
 [INFO] Elevated SQL user root found in .inmanage/.env.provision.
2025-07-16 13:39:30 [OK] Elevated credentials: Connection successful.
ERROR 1049 (42000) at line 1: Unknown database 'ninja'
2025-07-16 13:39:30 [WARN] Connection Possible. Database does not exist.
 [INFO] Trying to create database now.
2025-07-16 13:39:30 [OK] Database and user created successfully. If they already existed, they were untouched. Privileges were granted.
 [INFO] Removed DB_ELEVATED_USERNAME and DB_ELEVATED_PASSWORD from .inmanage/.env.provision if they were there.
2025-07-16 13:39:31 [WARN] Caution: Installation directory already exists! Current installation directory will get renamed. Proceed with installation? (yes/no):
yes
```

*The created provision file gets automatically recognized. Time to relax. The heavy lifting is done.*

```log
 [INFO] Installation starts now
 [INFO] Downloading Invoice Ninja version 5.12.8.
2025-07-16 13:50:51 [OK] Download successful.
 [INFO] Unpacking tar
 [INFO] Generating Key

   INFO  Application key set successfully.


   INFO  Caching framework bootstrap, configuration, and metadata.

  config ........................................................................................................... 125.51ms DONE
  events ............................................................................................................. 2.92ms DONE
  routes ........................................................................................................... 423.35ms DONE
  views ................................................................................................................. 17s DONE


   INFO  Application is already up.


   INFO  Preparing database.

  Creating migration table ......................................................................................... 100.38ms DONE

   INFO  Loading stored database schemas.

  database/schema/mysql-schema.sql ....................................................................................... 1s DONE

   INFO  Running migrations.

  2019_15_12_112000_create_elastic_migrations_table ................................................................. 38.56ms DONE
  2024_10_08_034355_add_account_e_invoice_quota ..................................................................... 16.63ms DONE
  2024_10_09_220533_invoice_gateway_fee ............................................................................. 15.53ms DONE
  2024_10_11_151650_create_e_invoice_tokens_table ................................................................... 63.28ms DONE
  2024_10_11_153311_add_e_invoicing_token ........................................................................... 13.82ms DONE
  2024_10_14_214658_add_routing_id_to_vendors_table ................................................................. 43.22ms DONE
  2024_10_18_211558_updated_currencies ............................................................................. 373.87ms DONE
  2024_11_11_043923_kill_switch_licenses_table ...................................................................... 15.25ms DONE
  2024_11_19_020259_add_entity_set_to_licenses_table ................................................................ 17.39ms DONE
  2024_11_21_011625_add_e_invoicing_logs_table ...................................................................... 39.05ms DONE
  2024_11_28_054808_add_referral_earning_column_to_users_table ...................................................... 14.97ms DONE
  2024_12_18_023826_2024_12_18_enforce_tax_data_model ............................................................... 72.82ms DONE
  2025_01_08_024611_2025_01_07_design_updates ....................................................................... 70.54ms DONE
  2025_01_15_222249_2025_01_16_zim_currency_change ................................................................... 1.71ms DONE
  2025_01_18_012550_2025_01_16_wst_currency .......................................................................... 1.46ms DONE
  2025_01_22_013047_2025_01_22_add_verification_setting_to_gocardless ............................................... 54.12ms DONE
  2025_02_12_000757_change_inr_currency_symbol ....................................................................... 3.67ms DONE
  2025_02_12_035916_create_sync_column_for_payments ................................................................. 29.53ms DONE
  2025_02_16_213917_add_e_invoice_column_to_recurring_invoices_table ................................................ 21.33ms DONE
  2025_02_20_224129_entity_location_schema ......................................................................... 603.40ms DONE
  2025_03_09_084919_add_payment_unapplied_pdf_variabels .............................................................. 5.18ms DONE
  2025_03_11_044138_update_blockonomics_help_url ..................................................................... 0.85ms DONE
  2025_03_13_073151_update_blockonomics .............................................................................. 0.64ms DONE
  2025_03_21_032428_add_sync_column_for_quotes ...................................................................... 17.17ms DONE
  2025_04_29_225412_add_guiler_currency .............................................................................. 1.39ms DONE
  2025_05_14_035605_add_signature_key_to_auth_net .................................................................... 0.69ms DONE
  2025_05_31_055839_add_docuninja_num_users ......................................................................... 14.46ms DONE
  2025_06_02_233158_update_date_format_for_d_m_y .................................................................... 26.57ms DONE


   INFO  Seeding database.

Running DatabaseSeeder
  Database\Seeders\ConstantsSeeder ....................................................................................... RUNNING
  Database\Seeders\ConstantsSeeder ................................................................................... 151 ms DONE

  Database\Seeders\PaymentLibrariesSeeder ................................................................................ RUNNING
  Database\Seeders\PaymentLibrariesSeeder ............................................................................ 301 ms DONE

  Database\Seeders\BanksSeeder ........................................................................................... RUNNING
  Database\Seeders\BanksSeeder ....................................................................................... 845 ms DONE

  Database\Seeders\CurrenciesSeeder ...................................................................................... RUNNING
  Database\Seeders\CurrenciesSeeder .................................................................................. 258 ms DONE

  Database\Seeders\LanguageSeeder ........................................................................................ RUNNING
  Database\Seeders\LanguageSeeder .................................................................................... 158 ms DONE

  Database\Seeders\CountriesSeeder ....................................................................................... RUNNING
  Database\Seeders\CountriesSeeder ................................................................................... 417 ms DONE

  Database\Seeders\IndustrySeeder ........................................................................................ RUNNING
  Database\Seeders\IndustrySeeder ..................................................................................... 72 ms DONE

  Database\Seeders\PaymentTypesSeeder .................................................................................... RUNNING
  Database\Seeders\PaymentTypesSeeder ................................................................................. 59 ms DONE

  Database\Seeders\GatewayTypesSeeder .................................................................................... RUNNING
  Database\Seeders\GatewayTypesSeeder ................................................................................. 64 ms DONE

  Database\Seeders\DateFormatsSeeder ..................................................................................... RUNNING
  Database\Seeders\DateFormatsSeeder .................................................................................. 47 ms DONE

  Database\Seeders\DesignSeeder .......................................................................................... RUNNING
  Database\Seeders\DesignSeeder ...................................................................................... 365 ms DONE

Wed, 16 Jul 2025 11:53:17 +0000 Create Single Account...

========================================
Setup Complete!

Login: https://billing.debian12vm.local
Username: admin@admin.com
Password: admin
========================================

Open your browser at https://billing.debian12vm.local to access the application.
The database and user are configured.

It's a good time to make your first backup now!

Cron installed (scheduler + backup).

dd@win81:/var/www/billing.debian12vm.local$

```

### 9.4. First Invoice Ninja Backup

Remember? You can just enter:

```bash
inmanage core backup
```

The first backup in your hand.

```text
All required commands are available.
Environment check starts.
Self configuration found
All settings are present in .inmanage/.env.inmanage.
No provision.
Proceeding without GH credentials authentication. If update fails, try to add credentials.
Creating backup directory.
Dumping database... Done.
Compressing Data. This may take a while. Hang on...
Cleaning up old backups.
insgesamt 182068
drwxr-xr-x 2 www-data www-data      4096  8. Jun 20:22 .
drwxr-xr-x 6 www-data www-data      4096  8. Jun 20:22 ..
-rw-r--r-- 1 www-data www-data 186428310  8. Jun 20:22 InvoiceNinja_20250608_202223.tar.gz
```

Snappdf is handled during the install flow. Cronjobs are installed automatically during provisioned installs (unless you disabled them).

### 9.5. Health check

Run a quick health check:

```bash
inm core health
```

Example output (sample data):

```text
2025-12-28 09:41:50 [INFO] [HEALTH] Starting system checks

== System ==
Subject        | Status | Detail
--------------------------------
System         | INFO   | Host: primary | OS: Ubuntu 24.04.2 LTS
System         | INFO   | Kernel: 6.8.0-90-generic | Arch: x86_64 | CPU cores: 2 | RAM: 1.9G
System         | INFO   | IPv4: 192.168.64.5
System         | INFO   | IPv6: fd0b:91b3:161a:be12:5054:ff:fe34:4c5f
System         | INFO   | Container: not detected

== Filesystem ==
Subject        | Status | Detail
--------------------------------
Filesystem     | INFO   | avail:2.9G used:16G mount:/ (Disk @base)
Filesystem     | OK     | Writable: /usr/share/nginx/local.invoiceninja.vm/ (Base dir)
Filesystem     | OK     | Writable: /usr/share/nginx/local.invoiceninja.vm/./invoiceninja (App dir) (Size: 1.6G)
Filesystem     | OK     | Writable: ./.backups (Backup dir) (Size: 371M)
Filesystem     | INFO   | Not writable: /home/ubuntu/.inmanage/cache (Cache global) or set INM_CACHE_GLOBAL_DIRECTORY to an accessible path. (local cache writable; consider fixing global cache for shared use)
Filesystem     | OK     | Writable: ./.cache (Cache local)

== App ==
Subject        | Status | Detail
--------------------------------
App            | OK     | App structure looks complete at /usr/share/nginx/local.invoiceninja.vm/./invoiceninja
App            | OK     | Languages loaded: 45

== ENV CLI ==
Subject        | Status | Detail
--------------------------------
ENV CLI        | INFO   | INM_ENFORCED_USER=www-data
ENV CLI        | INFO   | INM_BASE_DIRECTORY=/usr/share/nginx/local.invoiceninja.vm/
ENV CLI        | INFO   | INM_INSTALLATION_DIRECTORY=./invoiceninja
ENV CLI        | INFO   | INM_BACKUP_DIRECTORY=./.backups
ENV CLI        | INFO   | INM_CACHE_GLOBAL_DIRECTORY=/home/ubuntu/.inmanage/cache
ENV CLI        | INFO   | INM_CACHE_LOCAL_DIRECTORY=./.cache

== ENV APP ==
Subject        | Status | Detail
--------------------------------
ENV APP        | INFO   | APP_NAME=InvoiceNinja
ENV APP        | INFO   | APP_URL=https://billing.invoiceninja.local
ENV APP        | INFO   | PDF_GENERATOR=snappdf
ENV APP        | INFO   | APP_DEBUG=false

== CLI ==
Subject        | Status | Detail
--------------------------------
CLI            | INFO   | CLI: /usr/local/share/inmanage
CLI            | INFO   | Source: git checkout (branch=unknown commit=unknown)
CLI            | INFO   | Install mode: system (switch with: inm self switch-mode)
CLI            | INFO   | Newest file mtime: 2025-12-28 08:49:52 (lib/core/checks.sh)
CLI            | INFO   | inmanage.sh modified: 2025-12-28 07:59:24

== CLI Commands ==
Subject        | Status | Detail
--------------------------------
CLI Commands   | OK     | php
CLI Commands   | OK     | git
CLI Commands   | OK     | curl
CLI Commands   | OK     | tar
CLI Commands   | OK     | rsync
CLI Commands   | OK     | zip
CLI Commands   | OK     | unzip
CLI Commands   | OK     | composer
CLI Commands   | OK     | jq
CLI Commands   | OK     | awk
CLI Commands   | OK     | sed
CLI Commands   | OK     | find
CLI Commands   | OK     | xargs
CLI Commands   | OK     | touch
CLI Commands   | OK     | tee
CLI Commands   | OK     | sha256sum
CLI Commands   | OK     | DB client: mysql (both installed) (mysql + mariadb available)
CLI Commands   | OK     | DB dump: mysqldump (mysqldump + mariadb-dump available)

== Web Server ==
Subject        | Status | Detail
--------------------------------
Web Server     | INFO   | Nginx nginx/1.24.0 (Ubuntu)
Web Server     | INFO   | php-fpm running
Web Server     | INFO   | Port 80 open
Web Server     | INFO   | Port 443 open

== PHP CLI ==
Subject        | Status | Detail
--------------------------------
PHP CLI        | OK     | CLI 8.2.27
PHP CLI        | INFO   | CLI ini: /etc/php/8.2/cli/php.ini
PHP CLI        | OK     | >= 8.1
PHP CLI        | OK     | memory_limit unlimited (-1)
PHP CLI        | OK     | max_input_vars 5000
PHP CLI        | OK     | OPcache enabled

== PHP Web ==
Subject        | Status | Detail
--------------------------------
PHP Web        | INFO   | Version 8.2.27 (CLI 8.2.27)
PHP Web        | INFO   | php.ini /etc/php/8.2/fpm/php.ini
PHP Web        | INFO   | .user.ini <none>
PHP Web        | INFO   | memory_limit 1G
PHP Web        | INFO   | max_input_vars 10000
PHP Web        | INFO   | OPcache enabled
PHP Web        | INFO   | max_execution_time 30
PHP Web        | INFO   | post_max_size 8M
PHP Web        | INFO   | upload_max_filesize 2M

== PHP Extensions ==
Subject        | Status | Detail
--------------------------------
PHP Extensions | OK     | pdo_mysql
PHP Extensions | OK     | openssl
PHP Extensions | OK     | tokenizer
PHP Extensions | OK     | xml
PHP Extensions | OK     | gd
PHP Extensions | OK     | mbstring
PHP Extensions | OK     | bcmath
PHP Extensions | OK     | curl
PHP Extensions | OK     | zip
PHP Extensions | OK     | fileinfo
PHP Extensions | OK     | intl

== Network ==
Subject        | Status | Detail
--------------------------------
Network        | OK     | GitHub reachable
Network        | INFO   | DNS resolves: billing.invoiceninja.local
Network        | INFO   | Webserver certificate matches URL: https://billing.invoiceninja.local

== Mail Route ==
Subject        | Status | Detail
--------------------------------
Mail Route     | INFO   | Mail: not configured (MAIL_MAILER/MAIL_HOST unset)

== Database ==
Subject        | Status | Detail
--------------------------------
Database       | INFO   | Loaded DB vars from /usr/share/nginx/local.invoiceninja.vm/./invoiceninja/.env
Database       | INFO   | Target: host=localhost port=3306 db=indb user=indb
Database       | INFO   | Client: mysql
Database       | OK     | Connection ok to localhost:3306
Database       | INFO   | Server: 10.11.13-MariaDB-0ubuntu0.24.04.1 Ubuntu 24.04
Database       | INFO   | innodb_file_per_table=1
Database       | INFO   | max_allowed_packet=16777216
Database       | INFO   | charset=utf8mb4 collation=utf8mb4_general_ci
Database       | INFO   | sql_mode=STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION
Database       | OK     | Database 'indb' exists.

== Cron ==
Subject        | Status | Detail
--------------------------------
Cron           | OK     | Scheduler service present
Cron           | OK     | artisan schedule:run present
Cron           | OK     | backup cron present (03:24)

== Snappdf ==
Subject        | Status | Detail
--------------------------------
Snappdf        | INFO   | Chromium path: /usr/share/nginx/local.invoiceninja.vm/./invoiceninja/vendor/beganovich/snappdf/versions/ungoogled/chrome-linux/chrome
Snappdf        | OK     | Render ok (probe at ./.cache/snappdf_probe.pdf)

2025-12-28 09:41:57 [INFO] [HEALTH] Completed: OK=48 WARN=0 ERR=0
2025-12-28 09:41:57 [INFO] [HEALTH] Aggregate status: OK
```

## 10. Login to your Invoice Ninja installation

Since everything is working as expected it's time to login:

Open your local browser at <https://billing.debian12vm.local> to access the application. Most likely your browser will complain about the certificate –that's pretty normal, since you self-signed the certificate. You'll need to look for a link that says `Extended` or `Continue to billing.debian12vm.local (insecure)` and click that once. Your browser should remember your choice next time you open this page.

**Username:** <admin@admin.com>

**Password:** admin

Have fun. Don't forget to star and bookmark the <https://github.com/DrDBanner/inmanage/> script.
