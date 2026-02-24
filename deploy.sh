#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════
#  MKT — VPS Deploy Script
#  Usage:
#    ./deploy.sh install       First-time full setup
#    ./deploy.sh update        Pull latest & restart
#    ./deploy.sh domain        Configure/change domain
#    ./deploy.sh ssl           Setup Let's Encrypt SSL
#    ./deploy.sh status        Service & health status
#    ./deploy.sh logs          Tail application logs
#    ./deploy.sh restart       Restart the app
#    ./deploy.sh uninstall     Remove everything
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

log()  { echo -e "${G}[✓]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1"; }
err()  { echo -e "${R}[✗]${N} $1"; exit 1; }
step() { echo -e "\n${C}${B}═══ $1 ═══${N}"; }

need_root() {
  [[ $EUID -eq 0 ]] || err "Запустите от root: sudo $0 $*"
}

# ─── Detect OS ────────────────────────────────────────
detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="$ID"
    OS_VER="${VERSION_ID%%.*}"
  else
    err "Не удалось определить ОС. Поддерживаются Ubuntu/Debian."
  fi
  case "$OS_ID" in
    ubuntu|debian) ;;
    *) err "Поддерживаются только Ubuntu и Debian. Обнаружена: $OS_ID" ;;
  esac
  log "ОС: $PRETTY_NAME"
}

# ─── System packages ─────────────────────────────────
install_system_deps() {
  step "Системные пакеты"
  apt-get update -qq
  apt-get install -y -qq curl git nginx certbot python3-certbot-nginx ufw > /dev/null 2>&1
  log "nginx, certbot, git, ufw установлены"
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

  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - > /dev/null 2>&1
  apt-get install -y -qq nodejs > /dev/null 2>&1
  log "Node.js $(node -v) установлен"
}

# ─── App user ─────────────────────────────────────────
create_app_user() {
  step "Пользователь приложения"
  if id "$APP_USER" &>/dev/null; then
    log "Пользователь $APP_USER уже существует"
  else
    useradd --system --shell /usr/sbin/nologin --home-dir "$APP_DIR" "$APP_USER"
    log "Создан системный пользователь: $APP_USER"
  fi
}

# ─── Clone / Pull repo ───────────────────────────────
deploy_code() {
  step "Код приложения"

  if [[ -d "$APP_DIR/.git" ]]; then
    warn "Репозиторий уже клонирован — делаю git pull"
    cd "$APP_DIR"
    sudo -u "$APP_USER" git fetch origin
    sudo -u "$APP_USER" git reset --hard origin/main
    log "Код обновлён до последнего коммита"
  else
    if [[ -d "$APP_DIR" ]]; then
      warn "Папка $APP_DIR существует, но без .git — бэкаплю"
      mkdir -p "$BACKUP_DIR"
      mv "$APP_DIR" "${BACKUP_DIR}/app-$(date +%Y%m%d-%H%M%S)"
    fi
    git clone "$REPO_URL" "$APP_DIR"
    log "Репозиторий клонирован в $APP_DIR"
  fi

  # Data directory (persistent, not in repo)
  mkdir -p "$APP_DIR/data"
  chown -R "$APP_USER:$APP_USER" "$APP_DIR"
  log "Права файлов настроены"
}

# ─── NPM install ─────────────────────────────────────
install_deps() {
  step "NPM-зависимости"
  cd "$APP_DIR"
  sudo -u "$APP_USER" npm install --production --silent 2>&1 | tail -1
  log "Зависимости установлены"
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

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$APP_DIR/data
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$APP_NAME" --quiet
  systemctl restart "$APP_NAME"
  sleep 2

  if systemctl is-active --quiet "$APP_NAME"; then
    log "Сервис $APP_NAME запущен и добавлен в автозагрузку"
  else
    err "Сервис не запустился. Смотрите: journalctl -u $APP_NAME -n 30"
  fi
}

# ─── Firewall ─────────────────────────────────────────
setup_firewall() {
  step "Фаервол (UFW)"
  ufw --force enable > /dev/null 2>&1
  ufw allow ssh > /dev/null 2>&1
  ufw allow 'Nginx Full' > /dev/null 2>&1
  ufw reload > /dev/null 2>&1
  log "UFW: разрешены SSH, HTTP, HTTPS"
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

    # Cache static assets
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
  log "Nginx настроен: $domain → localhost:$APP_PORT"
}

# ─── SSL (Let's Encrypt) ─────────────────────────────
setup_ssl() {
  local domain="$1"
  step "SSL-сертификат для $domain"

  if [[ ! -f "/etc/nginx/sites-available/$APP_NAME" ]]; then
    err "Сначала настройте домен: $0 domain"
  fi

  read -rp "Email для Let's Encrypt (уведомления об истечении): " le_email
  [[ -z "$le_email" ]] && err "Email обязателен для Let's Encrypt"

  certbot --nginx \
    -d "$domain" \
    --email "$le_email" \
    --agree-tos \
    --non-interactive \
    --redirect

  log "SSL-сертификат установлен"
  log "Автопродление: certbot уже добавил таймер в systemd"

  systemctl list-timers certbot.timer --no-pager 2>/dev/null && \
    log "Таймер автопродления активен" || \
    warn "Добавьте cron: 0 3 * * * certbot renew --quiet"
}

# ─── Read current domain ──────────────────────────────
get_current_domain() {
  if [[ -f "/etc/nginx/sites-available/$APP_NAME" ]]; then
    grep -oP 'server_name\s+\K[^;]+' "/etc/nginx/sites-available/$APP_NAME" | head -1
  fi
}

# ─── Prompt for domain ────────────────────────────────
ask_domain() {
  local current
  current=$(get_current_domain 2>/dev/null || true)
  if [[ -n "$current" ]]; then
    echo -e "${C}Текущий домен: ${B}$current${N}"
    read -rp "Новый домен (Enter — оставить $current): " domain
    domain="${domain:-$current}"
  else
    read -rp "Введите домен (например, site.example.com): " domain
    [[ -z "$domain" ]] && err "Домен обязателен"
  fi
  echo "$domain"
}

# ─── Backup data ──────────────────────────────────────
backup_data() {
  if [[ -d "$APP_DIR/data" ]] && [[ "$(ls -A "$APP_DIR/data" 2>/dev/null)" ]]; then
    mkdir -p "$BACKUP_DIR"
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    cp -r "$APP_DIR/data" "$BACKUP_DIR/data-$ts"
    log "Данные скопированы в $BACKUP_DIR/data-$ts"
  fi
}

# ═══════════════════════════════════════════════════════
#  COMMANDS
# ═══════════════════════════════════════════════════════

cmd_install() {
  need_root
  echo -e "${B}${C}"
  echo "  ╔══════════════════════════════════════╗"
  echo "  ║   MKT — Установка на VPS             ║"
  echo "  ╚══════════════════════════════════════╝"
  echo -e "${N}"

  detect_os
  install_system_deps
  install_node
  create_app_user
  deploy_code
  install_deps
  setup_systemd

  local domain
  domain=$(ask_domain)
  setup_nginx "$domain"
  setup_firewall

  echo ""
  read -rp "Настроить SSL сейчас? (y/n): " do_ssl
  if [[ "$do_ssl" =~ ^[Yy]$ ]]; then
    setup_ssl "$domain"
  else
    warn "SSL пропущен. Позже: sudo $0 ssl"
  fi

  echo ""
  echo -e "${G}${B}══════════════════════════════════════${N}"
  echo -e "${G}${B}  Установка завершена!${N}"
  echo -e "${G}${B}══════════════════════════════════════${N}"
  echo ""
  echo -e "  Сайт:   ${C}http://$domain${N}"
  echo -e "  Админ:  ${C}http://$domain/admin.html${N}"
  echo -e "  Статус: ${C}sudo systemctl status $APP_NAME${N}"
  echo -e "  Логи:   ${C}sudo journalctl -u $APP_NAME -f${N}"
  echo -e "  Обновл: ${C}sudo $APP_DIR/deploy.sh update${N}"
  echo ""
}

cmd_update() {
  need_root
  echo -e "${B}${C}  Обновление MKT...${N}"

  backup_data

  step "Git pull"
  cd "$APP_DIR"
  sudo -u "$APP_USER" git fetch origin
  local LOCAL REMOTE
  LOCAL=$(git rev-parse HEAD)
  REMOTE=$(git rev-parse origin/main)

  if [[ "$LOCAL" == "$REMOTE" ]]; then
    log "Код уже актуален ($(echo "$LOCAL" | cut -c1-7))"
  else
    sudo -u "$APP_USER" git reset --hard origin/main
    log "Обновлено: $(echo "$LOCAL" | cut -c1-7) → $(echo "$REMOTE" | cut -c1-7)"
  fi

  install_deps
  setup_systemd

  echo ""
  echo -e "${G}${B}  Обновление завершено!${N}"
  echo -e "  Коммит: $(cd "$APP_DIR" && git log -1 --format='%h %s')"
  echo ""
}

cmd_domain() {
  need_root
  local domain
  domain=$(ask_domain)
  setup_nginx "$domain"
  systemctl reload nginx
  echo ""
  echo -e "${G}Домен настроен: ${B}$domain${N}"
  echo -e "Для SSL: ${C}sudo $0 ssl${N}"
}

cmd_ssl() {
  need_root
  local domain
  domain=$(get_current_domain)
  [[ -z "$domain" ]] && err "Домен не настроен. Сначала: sudo $0 domain"
  setup_ssl "$domain"
}

cmd_status() {
  echo -e "${B}${C}  MKT — Статус${N}\n"

  echo -e "${B}Сервис:${N}"
  if systemctl is-active --quiet "$APP_NAME" 2>/dev/null; then
    echo -e "  ${G}● Работает${N}"
    systemctl show "$APP_NAME" --property=ActiveEnterTimestamp --no-pager 2>/dev/null | \
      sed 's/ActiveEnterTimestamp=/  Запущен: /'
  else
    echo -e "  ${R}● Остановлен${N}"
  fi

  echo ""
  echo -e "${B}Nginx:${N}"
  if systemctl is-active --quiet nginx; then
    echo -e "  ${G}● Работает${N}"
    local domain
    domain=$(get_current_domain 2>/dev/null || echo "не настроен")
    echo "  Домен: $domain"
  else
    echo -e "  ${R}● Остановлен${N}"
  fi

  echo ""
  echo -e "${B}SSL:${N}"
  local domain
  domain=$(get_current_domain 2>/dev/null || true)
  if [[ -n "$domain" ]] && [[ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]]; then
    local expiry
    expiry=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$domain/fullchain.pem" 2>/dev/null | cut -d= -f2)
    echo -e "  ${G}● Активен${N} (до $expiry)"
  else
    echo -e "  ${Y}○ Не настроен${N}"
  fi

  echo ""
  echo -e "${B}Версия:${N}"
  if [[ -d "$APP_DIR/.git" ]]; then
    echo "  $(cd "$APP_DIR" && git log -1 --format='%h %s (%cr)')"
  else
    echo "  Не установлено"
  fi

  echo ""
  echo -e "${B}Порт $APP_PORT:${N}"
  if curl -sf "http://127.0.0.1:$APP_PORT/api/auth/status" > /dev/null 2>&1; then
    echo -e "  ${G}● API отвечает${N}"
  else
    echo -e "  ${R}● API не отвечает${N}"
  fi
  echo ""
}

cmd_logs() {
  journalctl -u "$APP_NAME" -f --no-pager -n 50
}

cmd_restart() {
  need_root
  systemctl restart "$APP_NAME"
  sleep 2
  if systemctl is-active --quiet "$APP_NAME"; then
    log "Сервис перезапущен"
  else
    err "Ошибка перезапуска. Логи: journalctl -u $APP_NAME -n 30"
  fi
}

cmd_uninstall() {
  need_root
  echo -e "${R}${B}  Удаление MKT${N}"
  echo ""
  read -rp "Вы уверены? Будет удалено ВСЁ (данные сохранятся в бэкапе). (yes/no): " confirm
  [[ "$confirm" != "yes" ]] && { echo "Отмена."; exit 0; }

  backup_data

  systemctl stop "$APP_NAME" 2>/dev/null || true
  systemctl disable "$APP_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/${APP_NAME}.service"
  systemctl daemon-reload

  rm -f "/etc/nginx/sites-enabled/$APP_NAME"
  rm -f "/etc/nginx/sites-available/$APP_NAME"
  systemctl reload nginx 2>/dev/null || true

  userdel "$APP_USER" 2>/dev/null || true
  rm -rf "$APP_DIR"

  log "MKT полностью удалён"
  [[ -d "$BACKUP_DIR" ]] && log "Бэкапы сохранены в $BACKUP_DIR"
}

# ─── Help ─────────────────────────────────────────────
show_help() {
  echo -e "${B}MKT Deploy Script${N}"
  echo ""
  echo "Использование: $0 <команда>"
  echo ""
  echo -e "  ${G}install${N}     Полная первичная установка"
  echo -e "  ${G}update${N}      Обновить код из GitHub и перезапустить"
  echo -e "  ${G}domain${N}      Настроить/сменить домен"
  echo -e "  ${G}ssl${N}         Установить SSL-сертификат"
  echo -e "  ${C}status${N}      Статус всех компонентов"
  echo -e "  ${C}logs${N}        Логи приложения (live)"
  echo -e "  ${C}restart${N}     Перезапустить приложение"
  echo -e "  ${R}uninstall${N}   Полное удаление"
  echo ""
  echo "Быстрая установка на чистом VPS:"
  echo -e "  ${Y}curl -sL https://raw.githubusercontent.com/superkai-sdk1/mkt/main/deploy.sh -o deploy.sh"
  echo -e "  chmod +x deploy.sh"
  echo -e "  sudo ./deploy.sh install${N}"
  echo ""
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
  *)         show_help ;;
esac
