#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DEFAULT="/opt/recargas-admin"

log()  { echo "  $*"; }
ok()   { echo "  ✔ $*"; }
fail() { echo "  ✖ ERROR: $*" >&2; exit 1; }

detect_pkg_manager() {
  if   command -v apt-get &>/dev/null; then echo "apt"
  elif command -v dnf     &>/dev/null; then echo "dnf"
  elif command -v yum     &>/dev/null; then echo "yum"
  elif command -v apk     &>/dev/null; then echo "apk"
  else fail "No se reconoce el gestor de paquetes (apt/dnf/yum/apk)."
  fi
}

install_pkg() {
  local pm; pm="$(detect_pkg_manager)"
  log "Instalando $* via $pm..."
  case "$pm" in
    apt) sudo apt-get install -y -qq "$@" ;;
    dnf) sudo dnf install -y "$@" ;;
    yum) sudo yum install -y "$@" ;;
    apk) sudo apk add --no-cache "$@" ;;
  esac
}

echo "[0/6] Verificando dependencias del sistema"
pm="$(detect_pkg_manager)"

if ! command -v curl    &>/dev/null; then install_pkg curl; fi
ok "curl $(curl --version | head -1 | awk '{print $2}')"

if ! command -v git     &>/dev/null; then install_pkg git; fi
ok "git $(git --version | awk '{print $3}')"

if ! command -v openssl &>/dev/null; then install_pkg openssl; fi
ok "openssl $(openssl version | awk '{print $2}')"

if ! command -v rsync   &>/dev/null; then install_pkg rsync || log "rsync no disponible, se usará cp"; fi

BUILD_MISSING=false
command -v make    &>/dev/null || BUILD_MISSING=true
command -v gcc     &>/dev/null || BUILD_MISSING=true
command -v g++     &>/dev/null || BUILD_MISSING=true
command -v python3 &>/dev/null || BUILD_MISSING=true
if [[ "$BUILD_MISSING" == "true" ]]; then
  log "Instalando herramientas de compilación..."
  case "$pm" in
    apt)     sudo apt-get install -y -qq build-essential python3 ;;
    dnf|yum) sudo "$pm" groupinstall -y "Development Tools"; sudo "$pm" install -y python3 ;;
    apk)     sudo apk add --no-cache alpine-sdk python3 ;;
  esac
fi
ok "make/gcc/python3 presentes"

if ! command -v node &>/dev/null || ! command -v npm &>/dev/null; then
  log "Instalando Node 20 LTS..."
  case "$pm" in
    apt)
      curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
      sudo apt-get install -y nodejs
      ;;
    dnf|yum)
      curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo -E bash -
      sudo "$pm" install -y nodejs
      ;;
    apk) sudo apk add --no-cache nodejs npm ;;
    *)   fail "Instala Node.js manualmente y vuelve a ejecutar." ;;
  esac
fi
ok "node $(node --version)  /  npm $(npm --version)"
echo ""

read -r -p "Directorio de instalación [$TARGET_DEFAULT]: " TARGET_DIR
TARGET_DIR="${TARGET_DIR:-$TARGET_DEFAULT}"
read -r -p "URL de repositorio git (opcional, Enter para usar archivos locales): " REPO_URL

mkdir -p "$TARGET_DIR"

echo "[1/6] Copiando archivos del proyecto"
if [[ -n "$REPO_URL" ]]; then
  if [[ -d "$TARGET_DIR/.git" ]]; then
    git -C "$TARGET_DIR" pull --ff-only
  else
    rm -rf "$TARGET_DIR"
    git clone "$REPO_URL" "$TARGET_DIR"
  fi
else
  # Estructura esperada: script en raíz del proyecto junto a package.json y carpeta server/
  if [[ -f "$SCRIPT_DIR/package.json" && -f "$SCRIPT_DIR/server/index.js" && -f "$SCRIPT_DIR/server/db.js" ]]; then
    if command -v rsync &>/dev/null; then
      rsync -a --delete \
        --exclude '.git' \
        --exclude 'node_modules' \
        "$SCRIPT_DIR/" "$TARGET_DIR/"
    else
      cp -r "$SCRIPT_DIR/." "$TARGET_DIR/"
    fi
    ok "Archivos copiados desde $SCRIPT_DIR"
  else
    fail "No se encontraron package.json, server/index.js y server/db.js en $SCRIPT_DIR. Coloca install.sh en la raíz del proyecto."
  fi
fi

[[ -f "$TARGET_DIR/package.json"    ]] || fail "Falta package.json en $TARGET_DIR"
[[ -f "$TARGET_DIR/server/index.js" ]] || fail "Falta server/index.js en $TARGET_DIR"
[[ -f "$TARGET_DIR/server/db.js"    ]] || fail "Falta server/db.js en $TARGET_DIR"

echo "[2/6] Generando credenciales y configuración"
ENV_FILE="$TARGET_DIR/.env"
SERVICE_FILE="/etc/systemd/system/recargas-admin-api.service"
APK_BOOTSTRAP_FILE="$TARGET_DIR/admin-app/local/bootstrap.properties"
CLIENT_BOOTSTRAP_FILE="$TARGET_DIR/client-android-app/local/bootstrap.properties"

PUBLIC_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
PUBLIC_HOST="${PUBLIC_HOST:-127.0.0.1}"
APP_PORT="80"

default_admin_user="admin_$(openssl rand -hex 2)"
default_admin_pass="Adm$(openssl rand -base64 9 | tr -dc 'A-Za-z0-9' | head -c 12)9"
secret="$(openssl rand -hex 32)"
app_admin_key="$(openssl rand -hex 24)"
app_client_key="$(openssl rand -hex 24)"

printf 'NODE_ENV=production\nBIND_HOST=0.0.0.0\nPORT=%s\nSECRET=%s\nAPP_ADMIN_KEY=%s\nAPP_CLIENT_KEY=%s\nBOOTSTRAP_ADMIN_USER=%s\nBOOTSTRAP_ADMIN_PASS=%s\nDIRECT_TLS=false\n' \
  "$APP_PORT" "$secret" "$app_admin_key" "$app_client_key" \
  "$default_admin_user" "$default_admin_pass" > "$ENV_FILE"

mkdir -p "$(dirname "$APK_BOOTSTRAP_FILE")"
printf 'API_BASE_URL=http://%s:%s\nAPP_ADMIN_KEY=%s\nDEFAULT_ADMIN_USER=%s\nDEFAULT_ADMIN_PASSWORD=%s\n' \
  "$PUBLIC_HOST" "$APP_PORT" "$app_admin_key" "$default_admin_user" "$default_admin_pass" > "$APK_BOOTSTRAP_FILE"

mkdir -p "$(dirname "$CLIENT_BOOTSTRAP_FILE")"
printf 'API_BASE_URL=http://%s:%s\nAPP_CLIENT_KEY=%s\nDEFAULT_CLIENT_USER=cliente_demo\n' \
  "$PUBLIC_HOST" "$APP_PORT" "$app_client_key" > "$CLIENT_BOOTSTRAP_FILE"

chmod 600 "$ENV_FILE" "$APK_BOOTSTRAP_FILE" "$CLIENT_BOOTSTRAP_FILE"
ok "Archivos de configuración creados"

echo "[3/6] Instalando dependencias npm..."
cd "$TARGET_DIR"
npm install --omit=dev
ok "npm install completado"

echo "  Instalando navegador Chromium para Playwright..."
npx playwright install chromium --with-deps 2>&1 | tail -5
ok "Playwright/Chromium listo"

echo "[4/6] Configurando systemd"
if command -v systemctl &>/dev/null; then

  sudo tee "$SERVICE_FILE" > /dev/null <<SERVICE
[Unit]
Description=Recargas Admin API (Node HTTP)
After=network.target

[Service]
Type=simple
WorkingDirectory=$TARGET_DIR
ExecStart=/usr/bin/node $TARGET_DIR/server/index.js
Restart=always
RestartSec=3
EnvironmentFile=$ENV_FILE
User=root
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$TARGET_DIR /tmp /root/.cache
ProtectHome=false

[Install]
WantedBy=multi-user.target
SERVICE

  ok "Servicio escrito en $SERVICE_FILE"

  echo "[5/6] Arrancando servicio"
  sudo systemctl daemon-reload
  sudo systemctl enable recargas-admin-api.service
  sudo systemctl restart recargas-admin-api.service
  sleep 2
  sudo systemctl status recargas-admin-api.service --no-pager || true

else
  log "systemctl no disponible."
  echo "[5/6] Arranque manual: cd $TARGET_DIR && node server/index.js"
fi

echo ""
echo "[6/6] ✔ Instalación completa"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Instalado en  : $TARGET_DIR"
echo "  API Base URL  : http://$PUBLIC_HOST:$APP_PORT"
echo "  X-App-Key adm : $app_admin_key"
echo "  X-App-Key cli : $app_client_key"
echo "  Admin user    : $default_admin_user"
echo "  Admin pass    : $default_admin_pass"
echo ""
echo "── admin-app/local/bootstrap.properties ────────"
echo "  API_BASE_URL=http://$PUBLIC_HOST:$APP_PORT"
echo "  APP_ADMIN_KEY=$app_admin_key"
echo "  DEFAULT_ADMIN_USER=$default_admin_user"
echo "  DEFAULT_ADMIN_PASSWORD=$default_admin_pass"
echo ""
echo "── client-android-app/local/bootstrap.properties"
echo "  API_BASE_URL=http://$PUBLIC_HOST:$APP_PORT"
echo "  APP_CLIENT_KEY=$app_client_key"
echo "  DEFAULT_CLIENT_USER=cliente_demo"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
