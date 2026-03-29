#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DEFAULT="/opt/recargas-admin"

read -r -p "Directorio de instalación [$TARGET_DEFAULT]: " TARGET_DIR
TARGET_DIR="${TARGET_DIR:-$TARGET_DEFAULT}"
read -r -p "URL de repositorio git (opcional, Enter para usar archivos locales): " REPO_URL

mkdir -p "$TARGET_DIR"

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
    rsync -a --delete \
      --exclude '.git' \
      --exclude 'node_modules' \
      "$SCRIPT_DIR/" "$TARGET_DIR/"
  else
    echo "No se encontraron archivos base. Creando estructura mínima..."
    mkdir -p "$TARGET_DIR/server" "$TARGET_DIR/admin-app/local"
    [[ -f "$TARGET_DIR/server/index.js" ]] || cat > "$TARGET_DIR/server/index.js" <<'JS'
console.log('Falta cargar lógica real del servidor en server/index.js')
JS
    [[ -f "$TARGET_DIR/package.json" ]] || cat > "$TARGET_DIR/package.json" <<'JSON'
{"name":"recargas-admin","version":"1.0.0","scripts":{"start":"node server/index.js"}}
JSON
  fi
fi

if [[ ! -f "$TARGET_DIR/package.json" || ! -f "$TARGET_DIR/server/index.js" ]]; then
  echo "Error: estructura incompleta en $TARGET_DIR (faltan package.json o server/index.js)."
  exit 1
fi

ENV_FILE="$TARGET_DIR/.env"
SERVICE_FILE="/etc/systemd/system/recargas-admin-api.service"
APK_BOOTSTRAP_FILE="$TARGET_DIR/admin-app/local/bootstrap.properties"

PUBLIC_HOST="$(hostname -I | awk '{print $1}')"
PUBLIC_HOST="${PUBLIC_HOST:-127.0.0.1}"
APP_PORT="80"

echo "[2/6] Generando credenciales y configuración"
default_admin_user="admin_$(openssl rand -hex 2)"
default_admin_pass="Adm$(openssl rand -base64 9 | tr -dc 'A-Za-z0-9' | head -c 12)9"
secret="$(openssl rand -hex 32)"
app_admin_key="$(openssl rand -hex 24)"

cat > "$ENV_FILE" <<ENV
NODE_ENV=production
BIND_HOST=0.0.0.0
PORT=$APP_PORT
SECRET=$secret
APP_ADMIN_KEY=$app_admin_key
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

cd "$TARGET_DIR"
command -v npm >/dev/null 2>&1 || { echo "npm no está instalado"; exit 1; }

echo "[3/6] Instalando dependencias npm"
npm install --omit=dev

echo "[4/6] Configurando systemd"
if command -v systemctl >/dev/null 2>&1; then
  sudo bash -c "cat > '$SERVICE_FILE'" <<SERVICE
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

  echo "[5/6] Arrancando servicio"
  sudo systemctl daemon-reload
  sudo systemctl enable recargas-admin-api.service
  sudo systemctl restart recargas-admin-api.service
  sudo systemctl status recargas-admin-api.service --no-pager || true
else
  echo "systemctl no disponible. Ejecuta manualmente:"
  echo "cd $TARGET_DIR && sudo npm start"
fi

echo "[6/6] Instalación completa"
echo "---------------------------------------------"
echo "Instalado en: $TARGET_DIR"
echo "API Base URL: http://$PUBLIC_HOST:$APP_PORT"
echo "X-App-Key: $app_admin_key"
echo "Usuario admin por defecto: $default_admin_user"
echo "Password admin por defecto: $default_admin_pass"
echo "Archivo bootstrap: $APK_BOOTSTRAP_FILE"
echo
echo "BLOQUE PARA COPIAR EN admin-app/local/bootstrap.properties"
echo "API_BASE_URL=http://$PUBLIC_HOST:$APP_PORT"
echo "APP_ADMIN_KEY=$app_admin_key"
echo "DEFAULT_ADMIN_USER=$default_admin_user"
echo "DEFAULT_ADMIN_PASSWORD=$default_admin_pass"
echo "---------------------------------------------"
