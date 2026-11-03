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

## Контроль конфигурации

```bash
# [VM]
(cd ~/devops-course-2026 && scripts/audit.sh); echo $?     # 0 — все проверки пройдены
```
