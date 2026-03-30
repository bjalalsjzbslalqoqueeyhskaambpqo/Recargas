#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DEFAULT="/opt/recargas-admin"

# ══════════════════════════════════════════════════════════════════════════════
# UTILIDADES
# ══════════════════════════════════════════════════════════════════════════════

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

# ══════════════════════════════════════════════════════════════════════════════
# [0/6] DEPENDENCIAS DEL SISTEMA
# ══════════════════════════════════════════════════════════════════════════════
echo "[0/6] Verificando dependencias del sistema"

pm="$(detect_pkg_manager)"

if ! command -v curl &>/dev/null; then install_pkg curl; fi
ok "curl $(curl --version | head -1 | awk '{print $2}')"

if ! command -v git &>/dev/null; then install_pkg git; fi
ok "git $(git --version | awk '{print $3}')"

if ! command -v openssl &>/dev/null; then install_pkg openssl; fi
ok "openssl $(openssl version | awk '{print $2}')"

if ! command -v rsync &>/dev/null; then install_pkg rsync || log "rsync no disponible, se usará cp como fallback"; fi

echo "  Verificando herramientas de compilación (make, gcc, g++, python3)..."
BUILD_MISSING=false
command -v make   &>/dev/null || BUILD_MISSING=true
command -v gcc    &>/dev/null || BUILD_MISSING=true
command -v g++    &>/dev/null || BUILD_MISSING=true
command -v python3 &>/dev/null || BUILD_MISSING=true

if [[ "$BUILD_MISSING" == "true" ]]; then
  log "Faltan herramientas de compilación. Instalando..."
  case "$pm" in
    apt) sudo apt-get install -y -qq build-essential python3 ;;
    dnf|yum) sudo "$pm" groupinstall -y "Development Tools"; sudo "$pm" install -y python3 ;;
    apk) sudo apk add --no-cache alpine-sdk python3 ;;
  esac
fi
ok "make $(make --version | head -1 | awk '{print $3}')  /  gcc $(gcc --version | head -1 | awk '{print $3}')  /  python3 $(python3 --version | awk '{print $2}')"

if ! command -v node &>/dev/null || ! command -v npm &>/dev/null; then
  log "Node.js / npm no encontrados. Instalando Node 20 LTS..."
  case "$pm" in
    apt)
      curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
      sudo apt-get install -y nodejs
      ;;
    dnf|yum)
      curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo -E bash -
      sudo "$pm" install -y nodejs
      ;;
    apk)
      sudo apk add --no-cache nodejs npm
      ;;
    *) fail "No sé instalar Node.js en este sistema. Instálalo manualmente." ;;
  esac
else
  NODE_MAJOR="$(node --version | sed 's/v//' | cut -d. -f1)"
  if [[ "$NODE_MAJOR" -ge 22 ]]; then
    log "Node $NODE_MAJOR detectado. better-sqlite3 requiere compilar desde fuente."
    ok "build-essential presente — better-sqlite3 se compilará al instalar"
  fi
fi

NODE_VER="$(node --version 2>/dev/null || echo '?')"
NPM_VER="$(npm --version  2>/dev/null || echo '?')"
ok "node $NODE_VER  /  npm $NPM_VER"

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# PREGUNTAS
# ══════════════════════════════════════════════════════════════════════════════
read -r -p "Directorio de instalación [$TARGET_DEFAULT]: " TARGET_DIR
TARGET_DIR="${TARGET_DIR:-$TARGET_DEFAULT}"
read -r -p "URL de repositorio git (opcional, Enter para usar archivos locales): " REPO_URL

mkdir -p "$TARGET_DIR"

# ══════════════════════════════════════════════════════════════════════════════
# [1/6] ARCHIVOS DEL PROYECTO
# ══════════════════════════════════════════════════════════════════════════════
if [[ -n "$REPO_URL" ]]; then
  echo "[1/6] Descargando proyecto desde repositorio..."
  if [[ -d "$TARGET_DIR/.git" ]]; then
    git -C "$TARGET_DIR" pull --ff-only
  else
    rm -rf "$TARGET_DIR"
    git clone "$REPO_URL" "$TARGET_DIR"
  fi
else
  echo "[1/6] Usando archivos locales de $SCRIPT_DIR"
  if [[ -f "$SCRIPT_DIR/package.json" && -f "$SCRIPT_DIR/server/index.js" ]]; then
    if command -v rsync &>/dev/null; then
      rsync -a --delete \
        --exclude '.git' \
        --exclude 'node_modules' \
        "$SCRIPT_DIR/" "$TARGET_DIR/"
    else
      cp -r "$SCRIPT_DIR/." "$TARGET_DIR/"
    fi
  else
    log "No se encontraron archivos base. Creando estructura mínima..."
    mkdir -p "$TARGET_DIR/server" "$TARGET_DIR/admin-app/local" "$TARGET_DIR/client-android-app/local"
    [[ -f "$TARGET_DIR/server/index.js" ]] || cat > "$TARGET_DIR/server/index.js" <<'JS'
console.log('Falta cargar lógica real del servidor en server/index.js')
JS
    [[ -f "$TARGET_DIR/package.json" ]] || cat > "$TARGET_DIR/package.json" <<'JSON'
{"name":"recargas-admin","version":"1.0.0","scripts":{"start":"node server/index.js"}}
JSON
  fi
fi

if [[ ! -f "$TARGET_DIR/package.json" || ! -f "$TARGET_DIR/server/index.js" ]]; then
  fail "Estructura incompleta en $TARGET_DIR (faltan package.json o server/index.js)."
fi

# ══════════════════════════════════════════════════════════════════════════════
# [2/6] CREDENCIALES Y CONFIGURACIÓN
# ══════════════════════════════════════════════════════════════════════════════
ENV_FILE="$TARGET_DIR/.env"
SERVICE_FILE="/etc/systemd/system/recargas-admin-api.service"
APK_BOOTSTRAP_FILE="$TARGET_DIR/admin-app/local/bootstrap.properties"
CLIENT_BOOTSTRAP_FILE="$TARGET_DIR/client-android-app/local/bootstrap.properties"

PUBLIC_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
PUBLIC_HOST="${PUBLIC_HOST:-127.0.0.1}"
APP_PORT="80"

echo "[2/6] Generando credenciales y configuración"

default_admin_user="admin_$(openssl rand -hex 2)"
default_admin_pass="Adm$(openssl rand -base64 9 | tr -dc 'A-Za-z0-9' | head -c 12)9"
secret="$(openssl rand -hex 32)"
app_admin_key="$(openssl rand -hex 24)"
app_client_key="$(openssl rand -hex 24)"

cat > "$ENV_FILE" <<ENV
NODE_ENV=production
BIND_HOST=0.0.0.0
PORT=$APP_PORT
SECRET=$secret
APP_ADMIN_KEY=$app_admin_key
APP_CLIENT_KEY=$app_client_key
BOOTSTRAP_ADMIN_USER=$default_admin_user
BOOTSTRAP_ADMIN_PASS=$default_admin_pass
DIRECT_TLS=false
ENV

mkdir -p "$(dirname "$APK_BOOTSTRAP_FILE")"
cat > "$APK_BOOTSTRAP_FILE" <<ENV
API_BASE_URL=http://$PUBLIC_HOST:$APP_PORT
APP_ADMIN_KEY=$app_admin_key
DEFAULT_ADMIN_USER=$default_admin_user
DEFAULT_ADMIN_PASSWORD=$default_admin_pass
ENV

chmod 600 "$ENV_FILE" "$APK_BOOTSTRAP_FILE"

mkdir -p "$(dirname "$CLIENT_BOOTSTRAP_FILE")"
cat > "$CLIENT_BOOTSTRAP_FILE" <<ENV
API_BASE_URL=http://$PUBLIC_HOST:$APP_PORT
APP_CLIENT_KEY=$app_client_key
DEFAULT_CLIENT_USER=cliente_demo
ENV

chmod 600 "$CLIENT_BOOTSTRAP_FILE"
ok "Archivos de configuración creados"

# ══════════════════════════════════════════════════════════════════════════════
# [3/6] DEPENDENCIAS NPM
# ══════════════════════════════════════════════════════════════════════════════
cd "$TARGET_DIR"
echo "[3/6] Instalando dependencias npm (puede tardar si compila módulos nativos)..."
npm install --omit=dev
ok "npm install completado"

# ══════════════════════════════════════════════════════════════════════════════
# [4/6] SYSTEMD
# ══════════════════════════════════════════════════════════════════════════════
echo "[4/6] Configurando systemd"

if command -v systemctl &>/dev/null; then

  sudo tee "$SERVICE_FILE" > /dev/null <<SERVICE
[Unit]
Description=Recargas Admin API (Node HTTP)
After=network.target

[Service]
Type=simple
WorkingDirectory=$TARGET_DIR
ExecStart=/usr/bin/env npm start
Restart=always
RestartSec=3
EnvironmentFile=$ENV_FILE
User=root
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$TARGET_DIR
ProtectHome=true

[Install]
WantedBy=multi-user.target
SERVICE

  ok "Servicio escrito en $SERVICE_FILE"

  echo "[5/6] Arrancando servicio"
  sudo systemctl daemon-reload
  sudo systemctl enable recargas-admin-api.service
  sudo systemctl restart recargas-admin-api.service
  sudo systemctl status recargas-admin-api.service --no-pager || true

else
  log "systemctl no disponible."
  echo "[5/6] Arranque manual:"
  echo "  cd $TARGET_DIR && sudo npm start"
fi

# ══════════════════════════════════════════════════════════════════════════════
# [6/6] RESUMEN
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "[6/6] ✔ Instalación completa"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Instalado en  : $TARGET_DIR"
echo "  API Base URL  : http://$PUBLIC_HOST:$APP_PORT"
echo "  X-App-Key     : $app_admin_key"
echo "  X-App-Key cli : $app_client_key"
echo "  Admin user    : $default_admin_user"
echo "  Admin pass    : $default_admin_pass"
echo "  Bootstrap     : $APK_BOOTSTRAP_FILE"
echo "  Bootstrap cli : $CLIENT_BOOTSTRAP_FILE"
echo ""
echo "── Copiar en bootstrap.properties ─────────────"
echo "  API_BASE_URL=http://$PUBLIC_HOST:$APP_PORT"
echo "  APP_ADMIN_KEY=$app_admin_key"
echo "  DEFAULT_ADMIN_USER=$default_admin_user"
echo "  DEFAULT_ADMIN_PASSWORD=$default_admin_pass"
echo ""
echo "── Copiar en client-android-app/local/bootstrap.properties ─────────────"
echo "  API_BASE_URL=http://$PUBLIC_HOST:$APP_PORT"
echo "  APP_CLIENT_KEY=$app_client_key"
echo "  DEFAULT_CLIENT_USER=cliente_demo"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
