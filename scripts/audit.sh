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

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
