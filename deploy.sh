#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════
#  MKT — Interactive VPS Deploy Script
#
#  Interactive:  ./deploy.sh
#  Direct:       ./deploy.sh install|update|domain|ssl|status|logs|restart|uninstall
# ═══════════════════════════════════════════════════════
set -euo pipefail

# ─── Config ───────────────────────────────────────────
APP_NAME="mkt"
APP_DIR="/opt/$APP_NAME"
APP_USER="mkt"
APP_PORT=3000
REPO_URL="https://github.com/superkai-sdk1/mkt.git"
NODE_MAJOR=20
BACKUP_DIR="/opt/${APP_NAME}-backups"

# ─── Colors ───────────────────────────────────────────
R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'
C='\033[0;36m'  B='\033[1m'     N='\033[0m'
DIM='\033[2m'

log()  { echo -e "  ${G}✓${N} $1"; }
warn() { echo -e "  ${Y}!${N} $1"; }
err()  { echo -e "  ${R}✗${N} $1"; exit 1; }
step() { echo -e "\n  ${C}${B}── $1${N}"; }
line() { echo -e "  ${DIM}──────────────────────────────────────${N}"; }

need_root() {
  [[ $EUID -eq 0 ]] || err "Запустите от root: sudo $0 ${1:-}"
}

pause() {
  echo ""
  read -rp "  Нажмите Enter для продолжения..." _
}

confirm() {
  local msg="${1:-Продолжить?}"
  echo ""
  read -rp "  $msg (y/n): " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

header() {
  clear 2>/dev/null || true
  echo -e "${C}"
  echo "  ╔══════════════════════════════════════╗"
  echo "  ║          MKT — Управление            ║"
  echo "  ╚══════════════════════════════════════╝"
  echo -e "${N}"
}

banner() {
  local title="$1"
  clear 2>/dev/null || true
  echo -e "${C}"
  echo "  ╔══════════════════════════════════════╗"
  printf "  ║  %-36s ║\n" "$title"
  echo "  ╚══════════════════════════════════════╝"
  echo -e "${N}"
}

# ─── Detect OS ────────────────────────────────────────
detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="$ID"
    OS_VER="${VERSION_ID%%.*}"
  else
    err "Не удалось определить ОС"
  fi
  case "$OS_ID" in
    ubuntu|debian) ;;
    *) err "Поддерживаются только Ubuntu/Debian (обнаружена: $OS_ID)" ;;
  esac
  log "ОС: $PRETTY_NAME"
}

# ─── System packages ─────────────────────────────────
install_system_deps() {
  step "Системные пакеты"
  echo -e "  ${DIM}Устанавливаю nginx, certbot, git, ufw...${N}"
  apt-get update -qq
  apt-get install -y -qq curl git nginx certbot python3-certbot-nginx ufw > /dev/null 2>&1
  log "Всё установлено"
}

# ─── Node.js ──────────────────────────────────────────
install_node() {
  step "Node.js"
  if command -v node &>/dev/null; then
    local current
    current=$(node -v | sed 's/v//' | cut -d. -f1)
    if (( current >= NODE_MAJOR )); then
      log "Node.js $(node -v) уже установлен"
      return
    fi
  fi
  echo -e "  ${DIM}Устанавливаю Node.js ${NODE_MAJOR}...${N}"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - > /dev/null 2>&1
  apt-get install -y -qq nodejs > /dev/null 2>&1
  log "Node.js $(node -v) установлен"
}

# ─── App user ─────────────────────────────────────────
create_app_user() {
  step "Пользователь"
  if id "$APP_USER" &>/dev/null; then
    log "Пользователь $APP_USER существует"
  else
    useradd --system --shell /usr/sbin/nologin --home-dir "$APP_DIR" "$APP_USER"
    log "Создан: $APP_USER"
  fi
}

# ─── Clone / Pull repo ───────────────────────────────
deploy_code() {
  step "Код приложения"
  if [[ -d "$APP_DIR/.git" ]]; then
    echo -e "  ${DIM}git pull...${N}"
    cd "$APP_DIR"
    sudo -u "$APP_USER" git fetch origin
    sudo -u "$APP_USER" git reset --hard origin/main
    log "Обновлён до последнего коммита"
  else
    if [[ -d "$APP_DIR" ]]; then
      mkdir -p "$BACKUP_DIR"
      mv "$APP_DIR" "${BACKUP_DIR}/app-$(date +%Y%m%d-%H%M%S)"
      warn "Старая папка перемещена в бэкап"
    fi
    echo -e "  ${DIM}git clone...${N}"
    git clone "$REPO_URL" "$APP_DIR"
    log "Клонировано в $APP_DIR"
  fi
  mkdir -p "$APP_DIR/data"
  chown -R "$APP_USER:$APP_USER" "$APP_DIR"
  log "Права настроены"
}

# ─── NPM install ─────────────────────────────────────
install_deps() {
  step "NPM-зависимости"
  cd "$APP_DIR"
  echo -e "  ${DIM}npm install...${N}"
  sudo -u "$APP_USER" npm install --production --silent 2>&1 | tail -1
  log "Готово"
}

# ─── Systemd service ─────────────────────────────────
setup_systemd() {
  step "Systemd-сервис"
  cat > "/etc/systemd/system/${APP_NAME}.service" <<EOF
[Unit]
Description=MKT Site Server
After=network.target

[Service]
Type=simple
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=PORT=$APP_PORT
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$APP_DIR
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$APP_NAME" --quiet
  systemctl restart "$APP_NAME"
  sleep 2

  if systemctl is-active --quiet "$APP_NAME"; then
    log "Запущен и добавлен в автозагрузку"
  else
    err "Не запустился. Логи: journalctl -u $APP_NAME -n 30"
  fi
}

# ─── Firewall ─────────────────────────────────────────
setup_firewall() {
  step "Фаервол"
  ufw --force enable > /dev/null 2>&1
  ufw allow ssh > /dev/null 2>&1
  ufw allow 'Nginx Full' > /dev/null 2>&1
  ufw reload > /dev/null 2>&1
  log "SSH + HTTP + HTTPS разрешены"
}

# ─── Nginx config ─────────────────────────────────────
setup_nginx() {
  local domain="$1"
  step "Nginx → $domain"

  cat > "/etc/nginx/sites-available/$APP_NAME" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_cache off;
        client_max_body_size 5m;
    }

    location ~* \.(css|js|svg|png|jpg|jpeg|webp|ico|woff2?)$ {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        expires 7d;
        add_header Cache-Control "public, immutable";
    }
}
EOF

  ln -sf "/etc/nginx/sites-available/$APP_NAME" "/etc/nginx/sites-enabled/$APP_NAME"
  rm -f /etc/nginx/sites-enabled/default
  nginx -t 2>&1 || err "Ошибка конфигурации Nginx"
  systemctl reload nginx
  log "Готово: $domain → localhost:$APP_PORT"
}

# ─── SSL (Let's Encrypt) ─────────────────────────────
setup_ssl() {
  local domain="$1"
  step "SSL → $domain"

  if [[ ! -f "/etc/nginx/sites-available/$APP_NAME" ]]; then
    err "Сначала настройте домен"
  fi

  echo ""
  read -rp "  Email для Let's Encrypt: " le_email
  [[ -z "$le_email" ]] && err "Email обязателен"

  echo -e "  ${DIM}Выпускаю сертификат...${N}"
  certbot --nginx \
    -d "$domain" \
    --email "$le_email" \
    --agree-tos \
    --non-interactive \
    --redirect

  log "SSL установлен"

  if systemctl list-timers certbot.timer --no-pager &>/dev/null; then
    log "Автопродление активно"
  else
    warn "Добавьте cron: 0 3 * * * certbot renew --quiet"
  fi
}

# ─── Helpers ──────────────────────────────────────────
get_current_domain() {
  if [[ -f "/etc/nginx/sites-available/$APP_NAME" ]]; then
    grep -oP 'server_name\s+\K[^;]+' "/etc/nginx/sites-available/$APP_NAME" | head -1
  fi
}

ask_domain() {
  local current domain
  current=$(get_current_domain 2>/dev/null || true)
  if [[ -n "$current" ]]; then
    echo -e "  Текущий домен: ${B}$current${N}" >&2
    echo "" >&2
    read -rp "  Новый домен (Enter — оставить): " domain
    domain="${domain:-$current}"
  else
    read -rp "  Введите домен (например site.example.com): " domain
    [[ -z "$domain" ]] && err "Домен обязателен"
  fi
  echo "$domain"
}

backup_data() {
  if [[ -d "$APP_DIR/data" ]] && [[ "$(ls -A "$APP_DIR/data" 2>/dev/null)" ]]; then
    mkdir -p "$BACKUP_DIR"
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    cp -r "$APP_DIR/data" "$BACKUP_DIR/data-$ts"
    log "Бэкап данных: $BACKUP_DIR/data-$ts"
  fi
}

is_installed() {
  [[ -d "$APP_DIR/.git" ]] && systemctl is-active --quiet "$APP_NAME" 2>/dev/null
}

# ═══════════════════════════════════════════════════════
#  COMMANDS
# ═══════════════════════════════════════════════════════

cmd_install() {
  need_root install
  banner "Установка"

  echo -e "  Будет установлено:"
  echo -e "    • Node.js ${NODE_MAJOR}, Nginx, Certbot, UFW"
  echo -e "    • Приложение из ${C}$REPO_URL${N}"
  echo -e "    • Systemd-сервис с автозапуском"
  echo ""
  confirm "Начать установку?" || { echo "  Отмена."; return; }

  detect_os
  install_system_deps
  install_node
  create_app_user
  deploy_code
  install_deps
  setup_systemd

  echo ""
  line
  local domain
  domain=$(ask_domain)
  setup_nginx "$domain"
  setup_firewall

  if confirm "Настроить SSL (Let's Encrypt)?"; then
    setup_ssl "$domain"
  else
    warn "SSL пропущен. Выберите «SSL» в меню позже."
  fi

  echo ""
  echo -e "  ${G}${B}┌──────────────────────────────────────┐${N}"
  echo -e "  ${G}${B}│       Установка завершена!            │${N}"
  echo -e "  ${G}${B}└──────────────────────────────────────┘${N}"
  echo ""
  echo -e "  Сайт:    ${C}http://$domain${N}"
  echo -e "  Админ:   ${C}http://$domain/admin.html${N}"
  echo ""
}

cmd_update() {
  need_root update
  banner "Обновление"

  if [[ ! -d "$APP_DIR/.git" ]]; then
    err "Приложение не установлено. Сначала выполните установку."
  fi

  local current_commit
  current_commit=$(cd "$APP_DIR" && git log -1 --format='%h %s')
  echo -e "  Текущий коммит: ${DIM}$current_commit${N}"
  echo ""
  confirm "Обновить до последней версии из GitHub?" || { echo "  Отмена."; return; }

  backup_data

  step "Git pull"
  cd "$APP_DIR"
  sudo -u "$APP_USER" git fetch origin
  local LOCAL REMOTE
  LOCAL=$(git rev-parse HEAD)
  REMOTE=$(git rev-parse origin/main)

  if [[ "$LOCAL" == "$REMOTE" ]]; then
    log "Код уже актуален"
  else
    sudo -u "$APP_USER" git reset --hard origin/main
    log "$(echo "$LOCAL" | cut -c1-7) → $(echo "$REMOTE" | cut -c1-7)"
  fi

  install_deps
  setup_systemd

  echo ""
  echo -e "  ${G}${B}Обновление завершено!${N}"
  echo -e "  Коммит: ${DIM}$(cd "$APP_DIR" && git log -1 --format='%h %s')${N}"
}

cmd_domain() {
  need_root domain
  banner "Настройка домена"

  local domain
  domain=$(ask_domain)
  echo ""
  confirm "Настроить Nginx для $domain?" || { echo "  Отмена."; return; }

  setup_nginx "$domain"

  echo ""
  echo -e "  ${G}${B}Домен настроен: $domain${N}"
  echo -e "  ${DIM}Для SSL выберите пункт «SSL» в меню${N}"
}

cmd_ssl() {
  need_root ssl
  banner "SSL-сертификат"

  local domain
  domain=$(get_current_domain)
  [[ -z "$domain" ]] && err "Домен не настроен. Сначала настройте домен."

  echo -e "  Домен: ${B}$domain${N}"
  echo -e "  Провайдер: Let's Encrypt (бесплатно)"
  echo -e "  Автопродление: да"
  echo ""
  confirm "Выпустить SSL-сертификат?" || { echo "  Отмена."; return; }

  setup_ssl "$domain"

  echo ""
  echo -e "  ${G}${B}SSL активен для $domain${N}"
}

cmd_status() {
  banner "Статус"

  # Service
  echo -e "  ${B}Приложение${N}"
  if systemctl is-active --quiet "$APP_NAME" 2>/dev/null; then
    echo -e "    ${G}●${N} Работает"
    local uptime_str
    uptime_str=$(systemctl show "$APP_NAME" --property=ActiveEnterTimestamp --no-pager 2>/dev/null | sed 's/ActiveEnterTimestamp=//')
    [[ -n "$uptime_str" ]] && echo -e "    ${DIM}Запущен: $uptime_str${N}"
  else
    echo -e "    ${R}●${N} Остановлен"
  fi

  echo ""
  echo -e "  ${B}Nginx${N}"
  if systemctl is-active --quiet nginx 2>/dev/null; then
    echo -e "    ${G}●${N} Работает"
    local domain
    domain=$(get_current_domain 2>/dev/null || true)
    if [[ -n "$domain" ]]; then
      echo -e "    Домен: ${C}$domain${N}"
    else
      echo -e "    ${DIM}Домен не настроен${N}"
    fi
  else
    echo -e "    ${R}●${N} Остановлен"
  fi

  echo ""
  echo -e "  ${B}SSL${N}"
  local domain
  domain=$(get_current_domain 2>/dev/null || true)
  if [[ -n "$domain" ]] && [[ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]]; then
    local expiry
    expiry=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$domain/fullchain.pem" 2>/dev/null | cut -d= -f2)
    echo -e "    ${G}●${N} Активен ${DIM}(до $expiry)${N}"
  else
    echo -e "    ${Y}○${N} Не настроен"
  fi

  echo ""
  echo -e "  ${B}API${N}"
  if curl -sf "http://127.0.0.1:$APP_PORT/api/auth/status" > /dev/null 2>&1; then
    echo -e "    ${G}●${N} Отвечает на :$APP_PORT"
  else
    echo -e "    ${R}●${N} Не отвечает"
  fi

  echo ""
  echo -e "  ${B}Версия${N}"
  if [[ -d "$APP_DIR/.git" ]]; then
    echo -e "    $(cd "$APP_DIR" && git log -1 --format='%h %s %C(dim)(%cr)%C(reset)')"
  else
    echo -e "    ${DIM}Не установлено${N}"
  fi
  echo ""
}

cmd_logs() {
  banner "Логи"
  echo -e "  ${DIM}Ctrl+C для выхода${N}"
  echo ""
  journalctl -u "$APP_NAME" -f --no-pager -n 50
}

cmd_restart() {
  need_root restart
  banner "Перезапуск"

  echo -e "  Сервис: ${B}$APP_NAME${N}"
  echo ""
  confirm "Перезапустить?" || { echo "  Отмена."; return; }

  echo -e "  ${DIM}Перезапускаю...${N}"
  systemctl restart "$APP_NAME"
  sleep 2

  if systemctl is-active --quiet "$APP_NAME"; then
    log "Сервис перезапущен"
  else
    err "Ошибка. Логи: journalctl -u $APP_NAME -n 30"
  fi
}

cmd_uninstall() {
  need_root uninstall
  banner "Удаление"

  echo -e "  ${R}Будет удалено:${N}"
  echo -e "    • Systemd-сервис $APP_NAME"
  echo -e "    • Nginx-конфигурация"
  echo -e "    • Папка $APP_DIR"
  echo -e "    • Пользователь $APP_USER"
  echo ""
  echo -e "  ${G}Данные будут сохранены в бэкапе.${N}"
  echo ""
  read -rp "  Введите «yes» для подтверждения: " confirm_text
  [[ "$confirm_text" != "yes" ]] && { echo "  Отмена."; return; }

  backup_data

  step "Удаление сервиса"
  systemctl stop "$APP_NAME" 2>/dev/null || true
  systemctl disable "$APP_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/${APP_NAME}.service"
  systemctl daemon-reload
  log "Сервис удалён"

  step "Удаление Nginx"
  rm -f "/etc/nginx/sites-enabled/$APP_NAME"
  rm -f "/etc/nginx/sites-available/$APP_NAME"
  systemctl reload nginx 2>/dev/null || true
  log "Конфиг Nginx удалён"

  step "Удаление файлов"
  userdel "$APP_USER" 2>/dev/null || true
  rm -rf "$APP_DIR"
  log "Папка и пользователь удалены"

  echo ""
  echo -e "  ${G}MKT полностью удалён${N}"
  [[ -d "$BACKUP_DIR" ]] && echo -e "  Бэкапы: ${C}$BACKUP_DIR${N}"
}

# ═══════════════════════════════════════════════════════
#  INTERACTIVE MENU
# ═══════════════════════════════════════════════════════

show_menu() {
  header

  local installed=false
  if [[ -d "$APP_DIR/.git" ]] 2>/dev/null; then
    installed=true
  fi

  if $installed; then
    local status_icon status_color
    if systemctl is-active --quiet "$APP_NAME" 2>/dev/null; then
      status_icon="●" status_color="$G"
    else
      status_icon="●" status_color="$R"
    fi
    echo -e "  Статус: ${status_color}${status_icon}${N}  $(get_current_domain 2>/dev/null || echo 'домен не настроен')"
    local current_ver
    current_ver=$(cd "$APP_DIR" 2>/dev/null && git log -1 --format='%h (%cr)' 2>/dev/null || echo '?')
    echo -e "  Версия: ${DIM}$current_ver${N}"
  else
    echo -e "  ${DIM}Приложение не установлено${N}"
  fi

  echo ""
  line

  if ! $installed; then
    echo ""
    echo -e "  ${G}${B}1${N}  Установка          ${DIM}Полная установка на этот сервер${N}"
    echo ""
    line
    echo ""
    echo -e "  ${DIM}0${N}  Выход"
    echo ""
    read -rp "  Выберите [0-1]: " choice
    echo "$choice"
    return
  fi

  echo ""
  echo -e "  ${G}${B}1${N}  Обновить            ${DIM}Скачать последний код из GitHub${N}"
  echo -e "  ${G}${B}2${N}  Домен               ${DIM}Настроить/сменить домен${N}"
  echo -e "  ${G}${B}3${N}  SSL                  ${DIM}Установить SSL-сертификат${N}"
  echo ""
  line
  echo ""
  echo -e "  ${C}${B}4${N}  Статус              ${DIM}Проверить все компоненты${N}"
  echo -e "  ${C}${B}5${N}  Логи                ${DIM}Журнал в реальном времени${N}"
  echo -e "  ${C}${B}6${N}  Перезапуск          ${DIM}Перезапустить приложение${N}"
  echo ""
  line
  echo ""
  echo -e "  ${Y}${B}7${N}  Переустановка       ${DIM}Полная установка заново${N}"
  echo -e "  ${R}${B}8${N}  Удаление            ${DIM}Удалить всё с сервера${N}"
  echo ""
  line
  echo ""
  echo -e "  ${DIM}0${N}  Выход"
  echo ""
  read -rp "  Выберите [0-8]: " choice
  echo "$choice"
}

interactive_loop() {
  while true; do
    local choice
    choice=$(show_menu)

    local installed=false
    [[ -d "$APP_DIR/.git" ]] 2>/dev/null && installed=true

    if ! $installed; then
      case "$choice" in
        1) cmd_install; pause ;;
        0|"") echo -e "\n  ${DIM}До свидания!${N}\n"; exit 0 ;;
        *) ;;
      esac
      continue
    fi

    case "$choice" in
      1) cmd_update; pause ;;
      2) cmd_domain; pause ;;
      3) cmd_ssl; pause ;;
      4) cmd_status; pause ;;
      5) cmd_logs ;;
      6) cmd_restart; pause ;;
      7) cmd_install; pause ;;
      8) cmd_uninstall; pause ;;
      0|"") echo -e "\n  ${DIM}До свидания!${N}\n"; exit 0 ;;
      *) ;;
    esac
  done
}

# ─── Main ─────────────────────────────────────────────
case "${1:-}" in
  install)   cmd_install ;;
  update)    cmd_update ;;
  domain)    cmd_domain ;;
  ssl)       cmd_ssl ;;
  status)    cmd_status ;;
  logs)      cmd_logs ;;
  restart)   cmd_restart ;;
  uninstall) cmd_uninstall ;;
  help|-h|--help)
    echo -e "${B}MKT Deploy Script${N}"
    echo ""
    echo "  $0            Интерактивное меню"
    echo "  $0 install    Полная установка"
    echo "  $0 update     Обновить из GitHub"
    echo "  $0 domain     Настроить домен"
    echo "  $0 ssl        Установить SSL"
    echo "  $0 status     Статус компонентов"
    echo "  $0 logs       Логи (live)"
    echo "  $0 restart    Перезапуск"
    echo "  $0 uninstall  Полное удаление"
    echo ""
    ;;
  "")        interactive_loop ;;
  *)
    echo -e "${R}Неизвестная команда: $1${N}"
    echo "Используйте: $0 help"
    exit 1
    ;;
esac
