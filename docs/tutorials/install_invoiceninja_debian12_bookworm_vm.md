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

<details>
<summary><strong>2.1.1–2.1.7: WSL & Debian VM Setup on Windows (click to unfold)</strong></summary>

#### 2.1.1. Enable WSL and Virtual Machine Platform

Open a terminal as **Administrator** (Press `[WIN]`, type `Terminal`, right click -> select `run as Administrator`.) and enable WSL:

*This enables or switches to WSL1. If you already use WSL you can skip it and just install the Debian image.* 
```powershell
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
```

Restart your computer.

#### 2.1.2. Install Debian

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
> ```  
> New-NetFirewallRule -DisplayName "Allow HTTPS Inbound" -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow
> 
> Add-MpPreference -ExclusionPath "$env:LOCALAPPDATA\Packages\TheDebianProject.DebianGNULinux_*\LocalState"
> ```

#### 2.1.4. Launch Debian Terminal

Open Terminal as your current user

```
wsl -d Debian
```
*This command logs you into the Debian VM*

#### 2.1.6. Update Debian

Update package lists and upgrade packages:
```bash
sudo apt update && sudo apt upgrade -y

# Install some dependencies NOW!

sudo apt install -y git curl wget unzip zip htop openssh-client libc-bin openssl
```

#### 2.1.8. Scheduler Task – Autostart and Shutdown the VM on Windows Start and Shutdown

To automatically start and stop your WSL Debian VM with Windows:

**Autostart on Windows boot:**
1. Press `[WIN]` and type `Task Scheduler`, then open it.
2. Click **Create Task**.
3. Under **General**, name it (e.g., `Start WSL Debian`).
4. Go to **Triggers** tab, click **New**, set **Begin the task** to `At startup`.
5. Go to **Actions** tab, click **New**, set **Action** to `Start a program`.
6. In **Program/script**, enter:
    ```
    wsl -d Debian
    ```
7. Click **OK** to save.

**Shutdown on Windows shutdown:**
1. Create another task as above, but in **Triggers** set **Begin the task** to `On shutdown`.
2. In **Actions**, use:
    ```
    wsl --shutdown
    ```
3. Click **OK**.

This ensures your Debian VM starts with Windows and shuts down cleanly when Windows powers off.

#### 2.1.9. Ready to Continue
You can now proceed with the tutorial – jump to [4. Name resolution (DNS)](#4-name-resolution-dns) and right after that skip to [6. Webserver](#6-webserver) since sudo is already available on the WSL Debian VM. All further commands should be run within your Debian terminal as your created VM's user.

*You can login to the WSL VM at any time from a new terminal by executing `wsl -d Debian`*

> ## SNAPPDF on WSL 1
> 
> *Snappdf seems not to work on WSL 1 VM's* 
> 
> So, leave the variable in the .env file like this when you configure the provision file: 
> ```  
> PDF_GENERATOR=hosted_ninja
> ```

</details>


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

##### 3.1.1. MacOS
Press [⌘ CMD] + [SPACE] -> Type `Terminal` -> Press [ENTER]

##### 3.1.2. Linux
Press [CTRL] + [ALT] + [T]

##### 3.1.3. Windows 11
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

#### 4.1. Open hosts file

##### 4.1.1. MacOS
*Open a new Terminal and paste:*
```bash
sudo nano /etc/hosts
```
##### 4.1.2. Linux
*Open a new Terminal and paste:*
```bash
sudo nano /etc/hosts
```
##### 4.1.3. Windows 11
*Open a new Terminal as Administrator:* 

*Press [⌘ WIN] -> Type `Terminal` -> Right-Mouseclick on `Terminal` -> select `run as Administrator` and paste:*
```powershell
notepad $env:WINDIR\System32\drivers\etc\hosts
```
#### 4.2. Edit hosts file

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

#### 4.3. Public Servers / DNS
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
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
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
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
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

sudo nginx -t

if systemctl is-system-running --quiet 2>/dev/null; then
  sudo systemctl enable nginx
  sudo systemctl start nginx
else
  sudo service nginx start
  grep -q 'pgrep nginx' ~/.bashrc || echo 'pgrep nginx >/dev/null || sudo service nginx start' >> ~/.bashrc
fi


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

Now restart webserver and install autostart php fpm

```bash
if systemctl is-system-running --quiet 2>/dev/null; then
  sudo systemctl restart php8.4-fpm
  sudo systemctl restart nginx
else
  sudo /etc/init.d/php8.4-fpm restart
  sudo service nginx restart
  grep -q 'php8.4-fpm' ~/.bashrc || echo "pgrep php-fpm8.4 >/dev/null || sudo /etc/init.d/php8.4-fpm start" >> ~/.bashrc
fi
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

Previously you have successfully setup a webserver, a database, and installed some mandatory additional packages. Now the fun begins. Head over to the previously created directory `/var/www/billing.debian12vm.local` and get the [inmanage installation script for Invoice Ninja](https://github.com/DrDBanner/inmanage/#readme). So, have your database credentials at hand and paste this code to start:

```bash
cd /var/www/billing.debian12vm.local
sudo -u www-data git clone https://github.com/DrDBanner/inmanage.git .inmanage && sudo -u www-data .inmanage/inmanage.sh
```

The installation procedure of the installation script starts. You can go with the defaults by pressing [enter] each, except for `Include DB password in backup`. You answer with `Y` instead.

```text
    _____   __                                       __
   /  _/ | / /___ ___  ____ _____  ____ _____ ____  / /
   / //  |/ / __ `__ \/ __ `/ __ \/ __ `/ __ `/ _ \/ /
 _/ // /|  / / / / / / /_/ / / / / /_/ / /_/ /  __/_/
/___/_/ |_/_/ /_/ /_/\__,_/_/ /_/\__,_/\__, /\___(_)
                                      /____/
INVOICE NINJA - MANAGEMENT SCRIPT



2025-07-16 13:32:31 [WARN] .inmanage/.env.inmanage configuration file for this script not found. Attempting to create it...
2025-07-16 13:32:31 [OK] Write Permissions OK.

========== Install Wizard ==========

2025-07-16 13:32:31 [BOLD] Just press [ENTER] to accept defaults.

Which shall be your base-directory? Must have a trailing slash. [/var/www/billing.debian12vm.local/] >

The current/future Invoice Ninja folder? Must be relative from $INM_BASE_DIRECTORY and can start with a . dot. [./invoiceninja] >

Modify database dump options: In doubt, keep defaults. [--default-character-set=utf8mb4 --no-tablespaces --skip-add-drop-table --quick --single-transaction] >

Backup Directory? [./_in_backups] > ./backups

Backup retention? Set to 7 for daily backups to keep 7 snapshots. Ensure enough disk space. [2] >

Include DB password in backup? (Y): May expose the password to other server users during runtime. (N): Assumes a secure .my.cnf file with credentials to avoid exposure. [N] > Y

Script user? Usually the webserver user. Ensure it matches your webserver setup. [www-data] >

Which shell should be used? In doubt, keep as is. [/usr/bin/bash] >

Path to the PHP executable? In doubt, keep as is. [/usr/bin/php] >

GitHub API credentials may be required on shared hosting. Use the format username:password or token:x-oauth. If provided, all curl commands will use these credentials; [0] >

2025-07-16 13:33:40 [OK] .inmanage/.env.inmanage has been created and configured.
 [INFO] Downloading .env.example for provisioning
 [INFO] No GH credentials set. If connection fails, try to add credentials.
 [INFO] Usage: ./inmanage.sh <update|backup|clean_install|cleanup_versions|cleanup_backups> [--force] [--debug]
 [INFO] Full Documentation https://github.com/DrDBanner/inmanage/#readme

```

Done. The script is downloaded, installed, and configured.

#### 9.1.1. Cherry on top
As a cherry on top you make it available to your local user everywhere. Copy and paste this code to extend your `~/.bashrc` and activate it:

```bash
echo 'inmanage() { cd /var/www/billing.debian12vm.local/ && sudo -u www-data /var/www/billing.debian12vm.local/inmanage.sh "$@"; }' >> ~/.bashrc
source ~/.bashrc
```

Now you can just enter `inmanage` everywhere.

### 9.2. Inmanage script provision

Now you copy over a configuration template for Invoice Ninja and modify it to your needs:

```bash
cd /var/www/billing.debian12vm.local/.inmanage/ && sudo -u www-data cp .env.example .env.provision
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
inmanage
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

Cronjob Setup:
  * * * * * www-data /usr/bin/php /var/www/billing.debian12vm.local/./invoiceninja/artisan schedule:run >> /dev/null 2>&1

Scheduled Backup:
  * 3 * * * www-data /usr/bin/bash -c "/var/www/billing.debian12vm.local/./inmanage.sh backup" >> /dev/null 2>&1

dd@win81:/var/www/billing.debian12vm.local$

```

### 9.4. First Invoice Ninja Backup

Remember? You can just enter: 

```bash
inmanage backup
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

### 9.5. Force an update

In order to enable snappdf properly you need to force an update once. Downloading and installing ungoogled chrome may take some time, so have patience. 

```bash
inmanage update --force

All required commands are available.
Environment check starts.
Self configuration found
All settings are present in .inmanage/.env.inmanage.
No provision.
Proceeding without GH credentials authentication. If update fails, try to add credentials.
Update starts now.
Downloading Invoice Ninja version 5.12.0...
Download successful.
Unpacking Data.

   INFO  Application cache cleared successfully.  


   INFO  Application is now in maintenance mode.  

Directory does not exist: /var/www/billing.debian12vm.local/./invoiceninja/public/storage/
This may be normal if this is an initial installation, or if your storage is located somewhere different. You may need to copy data manually.
'Maintenanace' file removed from /var/www/billing.debian12vm.local/./invoiceninja_20250608_203055/storage/framework/.

   INFO  Caching framework bootstrap, configuration, and metadata.  

  config .............................................................................................................................. 21.57ms DONE
  events ............................................................................................................................... 1.08ms DONE
  routes .............................................................................................................................. 63.19ms DONE
  views .............................................................................................................................. 278.29ms DONE


   INFO  Nothing to migrate.  

2025-06-08 06:30:59 2025-06-08 06:30:59 Running CheckData... on Connected to Default DB Fix Status = Just checking issues 
2025-06-08 06:30:59 0 clients with incorrect balances
2025-06-08 06:30:59 0 clients with incorrect paid to dates
2025-06-08 06:30:59 0 contacts without a contact_key
2025-06-08 06:30:59 0 clients without any contacts
2025-06-08 06:30:59 0 contacts without a contact_key
2025-06-08 06:30:59 0 vendors without any contacts
2025-06-08 06:30:59 0 wrong invoices with bad balance state
2025-06-08 06:30:59 0 Contacts with Send Email = true but no email address
2025-06-08 06:30:59 0 Payments with No currency set
2025-06-08 06:30:59 0 users with duplicate oauth ids
2025-06-08 06:30:59 Done: SUCCESS
2025-06-08 06:30:59 Total execution time in seconds: 0.071326971054077

   INFO  Application is already up.  

Snappdf configuration detected.
Download and install Chromium if needed.
Starting download. Ungoogled Chrome

Extracting
Archive extracted.
Completed! ungoogled currently in use.
Cleaning up old update directory versions.
insgesamt 32
drwxr-xr-x  8 www-data www-data 4096  8. Jun 20:30 .
drwxr-xr-x  4 root     root     4096  8. Jun 18:09 ..
drwxr-xr-x  2 www-data www-data 4096  8. Jun 20:22 _in_backups
drwxr-xr-x  3 www-data www-data 4096  8. Jun 20:18 .inmanage
lrwxrwxrwx  1 www-data www-data   55  8. Jun 19:01 inmanage.sh -> /var/www/billing.debian12vm.local/.inmanage/inmanage.sh
drwxr-xr-x  2 www-data www-data 4096  8. Jun 20:30 ._in_tempDownload
drwxr-xr-x 15 www-data www-data 4096  8. Jun 20:30 invoiceninja
drwxr-xr-x 15 www-data www-data 4096  8. Jun 20:18 invoiceninja_20250608_203055
drwxr-xr-x  3 www-data www-data 4096  8. Jun 18:09 _last_IN_20250608_201836
```

> [!TIP]
> Next time you want to update just do it like this:
> ```
> inmanage backup && inmanage update
> ``` 


### 9.6. Set the cronjob

In order to have Invoice Ninja working as expected you need to add the scheduler string into your cron service. In this version you add it to `/etc/cron.d`. This is preferred in automated setups.

```bash
echo '* * * * * www-data /usr/bin/php /var/www/billing.debian12vm.local/invoiceninja/artisan schedule:run >> /dev/null 2>&1' | sudo tee /etc/cron.d/invoiceninja
```

Now you can check if the cron service is alive:

```bash
if systemctl is-system-running --quiet 2>/dev/null; then
  echo "📦 Detected systemd – checking cron service status:"
  sudo systemctl status cron
else
  echo "systemd not active – checking via pgrep:"
  if pgrep cron >/dev/null; then
    echo "cron is running (non-systemd environment)"
    exit 0
  else
    echo "cron is NOT running. You should fix that. Temporarily you can run > sudo service cron start"
    exit 1
  fi
fi
```

This method avoids editing the crontab manually and ensures system-wide clarity.

## 10. Login to your Invoice Ninja installation

Since everything is working as expected it's time to login:

Open your local browser at https://billing.debian12vm.local to access the application. Most likely your browser will complain about the certificate –that's pretty normal, since you self-signed the certificate. You'll need to look for a link that says `Extended` or `Continue to billing.debian12vm.local (insecure)` and click that once. You browser should remember your choice next time you open this page.

**Username:** admin@admin.com 

**Password:** admin

Have fun. Don't forget to star and bookmark the https://github.com/DrDBanner/inmanage/ script.

