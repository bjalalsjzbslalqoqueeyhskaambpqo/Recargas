#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
SERVICE_FILE="/etc/systemd/system/recargas-admin-api.service"
APK_BOOTSTRAP_FILE="$ROOT_DIR/admin-app/local/bootstrap.properties"

PUBLIC_HOST="$(hostname -I | awk '{print $1}')"
PUBLIC_HOST="${PUBLIC_HOST:-127.0.0.1}"
APP_PORT="80"

echo "== Instalador Recargas Admin API (IP:80) =="
echo "Configuración automática sin preguntas."
echo "IP detectada: $PUBLIC_HOST"
echo "Puerto API: $APP_PORT"

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
User=root
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
  echo "systemctl no disponible. Inicia manualmente con: sudo npm start"
fi

echo
echo "Instalación finalizada."
echo "---------------------------------------------"
echo "DATOS PARA INCRUSTAR EN APK ADMIN"
echo "API Base URL: http://$PUBLIC_HOST:$APP_PORT"
echo "X-App-Key: $app_admin_key"
echo "Usuario admin por defecto: $default_admin_user"
echo "Password admin por defecto: $default_admin_pass"
echo "Archivo generado: $APK_BOOTSTRAP_FILE"
echo
echo "BLOQUE PARA COPIAR EN recargas/admin-app/local/bootstrap.properties"
echo "API_BASE_URL=http://$PUBLIC_HOST:$APP_PORT"
echo "APP_ADMIN_KEY=$app_admin_key"
echo "DEFAULT_ADMIN_USER=$default_admin_user"
echo "DEFAULT_ADMIN_PASSWORD=$default_admin_pass"
echo "---------------------------------------------"
