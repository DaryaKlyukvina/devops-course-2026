#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
set -euo pipefail

REMOTE="devops"                     # псевдоним из ~/.ssh/config (ПР № 5, шаг 1.6)
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
LOCAL_DIR="${REPO_ROOT}/site/"

die() { echo "deploy: $*" >&2; exit 1; }

# 1. Разбор аргумента --dry-run
DRY_RUN=""
case "${1:-}" in
  "")        ;;
  --dry-run) DRY_RUN="--dry-run" ;;
  *)         die "неизвестный аргумент: $1 (допустимо: --dry-run)" ;;
esac

# 2. Проверки по требованиям 4 и 5
[[ -f "${LOCAL_DIR}index.html" ]] || die "нет файла site/index.html — доставка отменена"
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
  die "в репозитории есть незафиксированные изменения — доставка отменена"
fi

# 3. Синхронизация: одно SSH-соединение, без интерактивного запроса пароля
rsync -az --delete --chmod=D755,F644 ${DRY_RUN} --itemize-changes \
  -e "ssh -o BatchMode=yes -o ConnectTimeout=5" \
  "$LOCAL_DIR" "${REMOTE}:${REMOTE_DIR}/"

# 4. При --dry-run — завершение без проверки доступности
if [[ -n "$DRY_RUN" ]]; then
  echo "deploy: пробный запуск, состояние сервера не изменено"
  exit 0
fi

# 5. Проверка доступности с проверкой сертификата
curl -fsS --max-time 5 --cacert "$CA_CERT" -o /dev/null "$SITE_URL/" \
  || die "ресурс ${SITE_URL} недоступен после доставки"
echo "deploy: доставлен коммит $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
