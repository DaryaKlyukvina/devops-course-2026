# Конфигурация виртуальной машины devops-vm

Документ описывает конфигурацию учебного сервера и позволяет восстановить её со снимка `01-clean-install`.
Команды с пометкой **[Хост]** выполняются в PowerShell на Windows 10, с пометкой **[VM]** — на сервере.

## 1. Параметры машины

| Параметр | Значение |
|---|---|
| Средство виртуализации | Oracle VirtualBox 7.2 |
| Имя машины | `devops-vm` |
| Гостевая ОС | Ubuntu Server 24.04.5 LTS (язык и раскладка English, без графической подсистемы) |
| Оперативная память | 2048 МБ |
| Процессор | 2 ядра |
| Диск | 25 ГБ, динамический VDI, «Use an entire disk» |
| Имя узла | `devops-vm`, полное имя `devops-vm.devops.local` |

## 2. Сетевые интерфейсы

| Адаптер | Тип | Интерфейс в ВМ | Адрес | Назначение |
|---|---|---|---|---|
| 1 | NAT | `enp0s3` | `10.0.2.15/24` (DHCP VirtualBox) | Выход в интернет (apt), SSH через проброс порта |
| 2 | Host-only (VirtualBox Host-Only Ethernet Adapter) | `enp0s8` | `192.168.56.101/24` (DHCP) | Прямой доступ с хоста: `devops.local`, HTTP/HTTPS |

Проверка: `ip -brief address`.

### Имя devops.local

- На хосте в `C:\Windows\System32\drivers\etc\hosts` (Блокнот от имени администратора): `192.168.56.101    devops.local`, затем `ipconfig /flushdns`.
- На сервере:

```bash
sudo hostnamectl set-hostname devops-vm
sudo sed -i 's/^127.0.1.1.*/127.0.1.1 devops-vm.devops.local devops-vm/' /etc/hosts
hostname -f        # devops-vm.devops.local
```

## 3. Правило проброса портов

Адаптер 1 (NAT) → Дополнительно → Проброс портов:

| Имя | Протокол | Адрес хоста | Порт хоста | Адрес гостя | Порт гостя |
|---|---|---|---|---|---|
| ssh | TCP | 127.0.0.1 | 2222 | (пусто) | 2222 |

До усиления защиты SSH (порт 22) порт гостя был 22; после шага 5 изменён на 2222.

## 4. Учётные записи

| Имя | Группы | Аутентификация | Назначение |
|---|---|---|---|
| `student` | `student adm cdrom sudo dip plugdev lxd` (создан установщиком) | пароль; вход по SSH запрещён (`AllowUsers devops`), только локальная консоль | резервный доступ через окно ВМ |
| `devops` | `devops sudo users` | по SSH только ключ ed25519; пароль используется для `sudo` | рабочая учётная запись |

Создание пользователя:

```bash
# [VM] под student
sudo adduser devops            # задать пароль, остальные поля пропустить
sudo usermod -aG sudo devops
groups devops                  # devops : devops sudo users
```

Ключевая пара (отдельная, не ключ от GitHub):

```powershell
# [Хост]
ssh-keygen -t ed25519 -C "devops-vm-key" -f $env:USERPROFILE\.ssh\devops_vm      # passphrase пустая
type $env:USERPROFILE\.ssh\devops_vm.pub | ssh devops@127.0.0.1 -p 2222 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

Права на сервере: `~/.ssh` — 700, `~/.ssh/authorized_keys` — 600 (`stat -c '%a %n' ~/.ssh ~/.ssh/authorized_keys`).

Файл `C:\Users\user\.ssh\config` на хосте:

```
Host devops
    HostName 127.0.0.1
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes

Host devops.local
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

Важно: файл сохраняется в кодировке ASCII/UTF-8 без BOM (`Add-Content -Encoding ascii`), иначе ssh не прочитает первую строку.

## 5. Служба SSH

- Порт: **2222**.
- Основной файл `/etc/ssh/sshd_config` не изменяется; эталонная копия — `/etc/ssh/sshd_config.backup`.
- Изменения — в дополняющем файле **`/etc/ssh/sshd_config.d/99-hardening.conf`**:

```
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers devops
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

Процедура применения (действующую сессию не закрывать до проверки в новом окне):

```bash
# [VM]
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf > /dev/null <<'EOF'
...содержимое выше...
EOF
sudo sshd -t && echo "Конфигурация корректна"
sudo sshd -T | grep -Ei "^(port|permitrootlogin|passwordauthentication|maxauthtries|allowusers)"
sudo systemctl disable --now ssh.socket      # в Ubuntu 24.04 порт иначе задаёт сокет systemd (22)
sudo systemctl enable --now ssh.service   # ОБЯЗАТЕЛЬНО: без enable служба не стартует после перезагрузки
sudo systemctl restart ssh
sudo ss -tlnp | grep sshd                    # 0.0.0.0:2222 и [::]:2222
```

Затем в VirtualBox сменить «Порт гостя» правила `ssh` на 2222 и проверить в новом окне:

```powershell
ssh devops                                                   # успех без пароля
ssh -p 2222 root@127.0.0.1                                   # Permission denied (publickey)
ssh -p 2222 -o PubkeyAuthentication=no devops@127.0.0.1      # Permission denied (publickey)
```

Значение `Authentications that can continue`: до усиления — `publickey,password`, после — `publickey`.

Проверка автозапуска: `systemctl is-enabled ssh` → `enabled`. Если после перезагрузки ВМ подключение
сбрасывается (`kex_exchange_identification: read: Connection reset`), войти в окне ВМ и выполнить
`sudo systemctl enable --now ssh`.

## 6. Правила межсетевого экрана

Политики по умолчанию: `deny (incoming)`, `allow (outgoing)`, `disabled (routed)`. Журналирование: `medium`.

| Порт | Действие | Комментарий |
|---|---|---|
| 2222/tcp (IPv4 и IPv6) | **LIMIT IN** | SSH rate-limited (блокировка источника при ≥ 6 соединений за 30 с) |
| 80/tcp (IPv4 и IPv6) | ALLOW IN | HTTP (ПР № 6) |
| 443/tcp (IPv4 и IPv6) | ALLOW IN | HTTPS (ПР № 6) |

Порядок команд (правило для SSH создаётся **до** включения):

```bash
# [VM]
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 2222/tcp comment 'SSH'      # НЕ "ufw allow ssh": это порт 22 из /etc/services
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw enable
sudo ufw delete allow 2222/tcp
sudo ufw limit 2222/tcp comment 'SSH rate-limited'
sudo ufw logging medium
sudo ufw status verbose
```

Предупреждение: из-за `limit` не запускать ssh/scp/rsync больше пяти раз за 30 секунд.

## 7. Снимки состояния

| Снимок | Момент создания |
|---|---|
| `01-clean-install` | 27.10.2026 5:16 — после установки ОС и `apt upgrade`, машина выключена |
| `02-keys-configured` | 27.10.2026 6:02 — пользователь `devops`, ключ, `~/.ssh/config` |
| `03-ssh-hardened` | 27.10.2026 6:41 — `99-hardening.conf`, порт 2222, проброс 2222→2222 |
| `04-nginx-https` | 03.11.2026 — Nginx, HTTPS, ресурс devops-site (ПР № 6) |
| `05-docker-compose` | 03.11.2026 — Docker Engine, проект `~/app` (ПР № 7) |

## 8. Веб-сервер

| Параметр | Значение |
|---|---|
| Пакет | `nginx` из репозитория Ubuntu (`sudo apt install -y nginx`), версия 1.24 |
| Процессы | главный — `root` (читает конфигурацию, открывает порты 80/443, загружает ключ TLS), рабочие — `www-data` |
| Конфигурация ресурса | `/etc/nginx/sites-available/devops-site`, ссылка в `/etc/nginx/sites-enabled/`; ссылка `sites-enabled/default` удалена (файл `sites-available/default` сохранён) |
| Каталог ресурса | `/var/www/devops-site`, владелец `devops:devops`, каталоги 755, файлы 644 |
| Сертификат | `/etc/ssl/certs/devops.crt`, `root:root`, 644, самоподписанный, CN и SAN `devops.local`, срок 365 дней |
| Закрытый ключ | `/etc/ssl/private/devops.key`, `root:root`, **600** (рабочие процессы его не читают) |
| Журналы | `/var/log/nginx/devops-site.access.log`, `/var/log/nginx/devops-site.error.log` |

Формирование сертификата:

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key -out /etc/ssl/certs/devops.crt \
  -subj "/CN=devops.local" -addext "subjectAltName=DNS:devops.local"
```

Конфигурация `/etc/nginx/sites-available/devops-site`:

```nginx
server {                                   # HTTP -> HTTPS
    listen 80;
    listen [::]:80;
    server_name devops.local;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name devops.local;
    ssl_certificate     /etc/ssl/certs/devops.crt;
    ssl_certificate_key /etc/ssl/private/devops.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    root /var/www/devops-site;
    index index.html;
    location / {
        try_files $uri $uri/ =404;
    }
    error_page 404 /404.html;
    access_log /var/log/nginx/devops-site.access.log;
    error_log /var/log/nginx/devops-site.error.log;
}
```

Применение без прерывания обслуживания: `sudo nginx -t && sudo systemctl reload nginx` (не `restart`). HSTS не включается (сертификат самоподписанный).

Каталог ресурса:

```bash
sudo mkdir -p /var/www/devops-site
sudo chown -R devops:devops /var/www/devops-site
sudo ln -s /etc/nginx/sites-available/devops-site /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
```

Доставка содержимого — с хоста (WSL 1) сценарием `scripts/deploy.sh` (rsync `--delete --chmod=D755,F644`, одно SSH-соединение, проверка `curl --cacert ~/devops.crt`). Доверенный сертификат на хосте: `scp devops:/etc/ssl/certs/devops.crt ~/devops.crt`.

## 9. Контейнеризация

| Параметр | Значение |
|---|---|
| Docker Engine | пакеты `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin` из официального репозитория `download.docker.com` (пакет `docker.io` не используется); версия — `docker version --format '{{.Server.Version}}'` |
| Группа docker | `devops` (имеет sudo). Участник группы docker фактически получает права root, поэтому другие учётные записи не добавляются |
| Проект | `~/app` пользователя devops (`/home/devops/app`), доставляется с хоста: `rsync -avz --delete --exclude=.env app/ devops:app/` |
| Секреты | `~/app/.env`, права **600**, создаётся только на сервере, в репозиторий не попадает (`.gitignore`, `.dockerignore`) |
| Сервисы | `app` (образ `devops-app:1.0`, процесс от пользователя `app`), `db` (`postgres:16-alpine`, healthcheck `pg_isready`) |
| Порты | `127.0.0.1:5000` → `app:5000`; порт 5432 не публикуется |
| Сеть | пользовательская сеть `app_backend` (bridge), приложение обращается к СУБД по имени `db` |
| Том | `app_db_data` → `/var/lib/postgresql/data` |
| Обратный прокси | `https://devops.local/app/` → `http://127.0.0.1:5000/` |

Установка Docker Engine:

```bash
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker devops        # затем новая SSH-сессия
docker run --rm hello-world
```

Если Docker Hub недоступен, в `/etc/docker/daemon.json` задаётся зеркало: `{ "registry-mirrors": ["https://mirror.gcr.io"] }`, затем `sudo systemctl restart docker`.

Секрет на сервере:

```bash
cd ~/app
cp .env.example .env
chmod 600 .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/" .env
docker compose up -d --build
docker compose ps        # db — (healthy)
```

Фрагмент блока HTTPS в `/etc/nginx/sites-available/devops-site` (перед `error_page`):

```nginx
    location /app/ {
        proxy_pass http://127.0.0.1:5000/;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
```

Публикация порта на `0.0.0.0` обходит UFW (правила Docker в iptables применяются раньше), поэтому порт приложения публикуется только на `127.0.0.1`. `docker compose down -v` удаляет том с данными — не выполнять на рабочем сервере.

## Контроль конфигурации

```bash
# [VM]
(cd ~/devops-course-2026 && scripts/audit.sh); echo $?     # 0 — все проверки пройдены
```
