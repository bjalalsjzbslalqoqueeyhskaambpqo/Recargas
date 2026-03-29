#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
SERVICE_FILE="/etc/systemd/system/recargas-admin-api.service"

echo "== Instalador Recargas Admin API (HTTP) =="
echo "Este modo instala solo backend API para entorno controlado detrás de Cloudflare (nube naranja)."
echo

read -r -p "Usuario administrador inicial: " ADMIN_USER
read -r -s -p "Contraseña administrador inicial: " ADMIN_PASS
echo
read -r -p "Puerto API interno [3000]: " APP_PORT
APP_PORT="${APP_PORT:-3000}"

if [[ -z "$ADMIN_USER" || -z "$ADMIN_PASS" ]]; then
  echo "Error: usuario y contraseña admin son obligatorios."
  exit 1
fi

SECRET="$(openssl rand -hex 32)"

cat > "$ENV_FILE" <<ENV
NODE_ENV=production
BIND_HOST=0.0.0.0
PORT=$APP_PORT
SECRET=$SECRET
BOOTSTRAP_ADMIN_USER=$ADMIN_USER
BOOTSTRAP_ADMIN_PASS=$ADMIN_PASS
DIRECT_TLS=false
ENV

chmod 600 "$ENV_FILE"

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
echo "Admin inicial: $ADMIN_USER"
echo "API: http://TU_IP_O_HOST:$APP_PORT/api/status"
