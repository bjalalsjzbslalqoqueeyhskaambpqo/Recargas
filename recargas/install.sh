#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
SERVICE_FILE="/etc/systemd/system/recargas-admin-api.service"
APK_BOOTSTRAP_FILE="$ROOT_DIR/admin-app/local/bootstrap.properties"

echo "== Instalador Recargas Admin API (HTTP) =="
echo "Este instalador deja el servidor listo y genera datos para incrustar en el APK Admin."
echo

read -r -p "Host/IP público para el APK (ej: api.midominio.com o 1.2.3.4): " PUBLIC_HOST
read -r -p "Puerto API interno [3000]: " APP_PORT
APP_PORT="${APP_PORT:-3000}"

if [[ -z "$PUBLIC_HOST" ]]; then
  echo "Error: host público requerido."
  exit 1
fi

DEFAULT_ADMIN_USER="admin_$(openssl rand -hex 2)"
DEFAULT_ADMIN_PASS="Adm$(openssl rand -base64 9 | tr -dc 'A-Za-z0-9' | head -c 12)9"
SECRET="$(openssl rand -hex 32)"
APP_ADMIN_KEY="$(openssl rand -hex 24)"

cat > "$ENV_FILE" <<ENV
NODE_ENV=production
BIND_HOST=0.0.0.0
PORT=$APP_PORT
SECRET=$SECRET
APP_ADMIN_KEY=$APP_ADMIN_KEY
BOOTSTRAP_ADMIN_USER=$DEFAULT_ADMIN_USER
BOOTSTRAP_ADMIN_PASS=$DEFAULT_ADMIN_PASS
DIRECT_TLS=false
ENV

mkdir -p "$(dirname "$APK_BOOTSTRAP_FILE")"
cat > "$APK_BOOTSTRAP_FILE" <<ENV
API_BASE_URL=http://$PUBLIC_HOST:$APP_PORT
APP_ADMIN_KEY=$APP_ADMIN_KEY
DEFAULT_ADMIN_USER=$DEFAULT_ADMIN_USER
DEFAULT_ADMIN_PASSWORD=$DEFAULT_ADMIN_PASS
ENV

chmod 600 "$ENV_FILE" "$APK_BOOTSTRAP_FILE"

cd "$ROOT_DIR"
command -v npm >/dev/null 2>&1 || { echo "npm no está instalado"; exit 1; }

echo "Instalando dependencias..."
npm install --omit=dev

if command -v systemctl >/dev/null 2>&1; then
  echo "Configurando servicio systemd..."

  sudo bash -c "cat > '$SERVICE_FILE'" <<SERVICE
[Unit]
Description=Recargas Admin API (Node HTTP)
After=network.target

[Service]
Type=simple
WorkingDirectory=$ROOT_DIR
ExecStart=/usr/bin/env npm start
Restart=always
RestartSec=3
EnvironmentFile=$ENV_FILE
User=$(whoami)
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$ROOT_DIR
ProtectHome=true

[Install]
WantedBy=multi-user.target
SERVICE

  sudo systemctl daemon-reload
  sudo systemctl enable recargas-admin-api.service
  sudo systemctl restart recargas-admin-api.service
  sudo systemctl status recargas-admin-api.service --no-pager || true
else
  echo "systemctl no disponible. Inicia manualmente con: npm start"
fi

echo
echo "Instalación finalizada."
echo "---------------------------------------------"
echo "DATOS PARA INCRUSTAR EN APK ADMIN"
echo "API Base URL: http://$PUBLIC_HOST:$APP_PORT"
echo "X-App-Key: $APP_ADMIN_KEY"
echo "Usuario admin por defecto: $DEFAULT_ADMIN_USER"
echo "Password admin por defecto: $DEFAULT_ADMIN_PASS"
echo "Archivo generado: $APK_BOOTSTRAP_FILE"
echo
echo "BLOQUE PARA COPIAR EN recargas/admin-app/local/bootstrap.properties"
echo "API_BASE_URL=http://$PUBLIC_HOST:$APP_PORT"
echo "APP_ADMIN_KEY=$APP_ADMIN_KEY"
echo "DEFAULT_ADMIN_USER=$DEFAULT_ADMIN_USER"
echo "DEFAULT_ADMIN_PASSWORD=$DEFAULT_ADMIN_PASS"
echo "---------------------------------------------"
