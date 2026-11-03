#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo " [OK]    $desc"; ((PASS++))
    else
        echo " [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"; ((FAIL++))
    fi
}

echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
SSHD=$(sudo sshd -T)
check "Вход от имени root запрещён"        "no" "$(awk '/^permitrootlogin/{print $2}' <<<"$SSHD")"
check "Парольная аутентификация отключена" "no" "$(awk '/^passwordauthentication/{print $2}' <<<"$SSHD")"
SSH_PORT=$(awk '/^port /{print $2}' <<<"$SSHD")
check "Порт SSH отличен от 22 (сейчас $SSH_PORT)" "yes" "$([[ -n "$SSH_PORT" && "$SSH_PORT" != "22" ]] && echo yes || echo no)"
check "MaxAuthTries равно 3"               "3"  "$(awk '/^maxauthtries/{print $2}' <<<"$SSHD")"

echo "[2] Межсетевой экран"
UFW=$(sudo ufw status verbose)
check "Межсетевой экран активен"           "active" "$(awk '/^Status:/{print $2}' <<<"$UFW")"
check "Политика для входящего трафика deny" "deny"  "$(awk '/^Default:/{print $2}' <<<"$UFW")"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "              %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"
CERT=/etc/ssl/certs/devops.crt
CERT_DAYS="${CERT_DAYS:-30}"          # порог можно завысить для проверки: CERT_DAYS=400 scripts/audit.sh
check "Служба nginx активна"                     "active" "$(systemctl is-active nginx 2>/dev/null)"
check "Конфигурация nginx корректна (nginx -t)"  "0"      "$(sudo nginx -t >/dev/null 2>&1; echo $?)"
check "Сертификат действует ещё ${CERT_DAYS} дн." "0"      "$(openssl x509 -checkend $((CERT_DAYS*86400)) -noout -in "$CERT" >/dev/null 2>&1; echo $?)"
check "Нет файлов ресурса, доступных для записи всем" "" "$(find /var/www/devops-site -perm -o+w 2>/dev/null | tr '\n' ' ')"
check "Права закрытого ключа TLS равны 600"      "600"    "$(sudo stat -c '%a' /etc/ssl/private/devops.key 2>/dev/null)"

echo "[5] Контейнеризация"
check "Служба docker активна"                    "active"  "$(systemctl is-active docker 2>/dev/null)"
check "Контейнер СУБД app-db-1 в состоянии healthy" "healthy" "$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null)"
check "Порты 5000 и 5432 слушаются только на 127.0.0.1" "" "$(ss -tlnH | awk '$4 ~ /:(5000|5432)$/ && $4 !~ /^127\.0\.0\.1:/ {printf "%s ", $4}')"
check "Права файла ~/app/.env равны 600"         "600"     "$(stat -c '%a' "$HOME/app/.env" 2>/dev/null)"

echo "[6] Контрольная работа № 2"
KR2="$HOME/kr2"; KR2_PORT=8003
dc() { docker compose --project-directory "$KR2" "$@" 2>/dev/null; }
REDIS_ID=$(dc ps -q redis)
check "Контейнер сервиса redis в состоянии healthy" "healthy" "$( [[ -n "$REDIS_ID" ]] && docker inspect -f '{{.State.Health.Status}}' "$REDIS_ID" 2>/dev/null)"
check "Порт $KR2_PORT опубликован только на 127.0.0.1" "127.0.0.1:$KR2_PORT" "$(dc port app $KR2_PORT | sort -u | tr '\n' ' ' | sed 's/ $//')"
check "Права файла ~/kr2/.env равны 600"         "600"     "$(stat -c '%a' "$KR2/.env" 2>/dev/null)"
check "Сертификат kr2.crt действует ещё ${CERT_DAYS} дн." "0" "$(openssl x509 -checkend $((CERT_DAYS*86400)) -noout -in /etc/ssl/certs/kr2.crt >/dev/null 2>&1; echo $?)"
check "Ресурс kr2 активирован в sites-enabled"   "/etc/nginx/sites-available/kr2" "$(readlink -f /etc/nginx/sites-enabled/kr2 2>/dev/null)"

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
