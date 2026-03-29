#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
GATEWAY_ENV_FILE="$ROOT_DIR/.gateway.env"
CERTS_DIR="$ROOT_DIR/certs"
APP_SERVICE_FILE="/etc/systemd/system/recargas-app.service"
GW_SERVICE_FILE="/etc/systemd/system/recargas-gateway.service"
EDITOR_CMD="${EDITOR:-nano}"

mkdir -p "$CERTS_DIR"

CERT_FILE="$CERTS_DIR/cloudflare-origin-cert.pem"
KEY_FILE="$CERTS_DIR/cloudflare-origin-key.pem"

echo "== Instalador Recargas (Node + Gateway Go) =="
echo
echo "Este instalador configura:"
echo "- App Node en 127.0.0.1:3000 (interno)"
echo "- Gateway Go HTTPS en :443 con ruta /recargas"
echo

echo "Pega Cloudflare Origin Certificate (PEM) en 5 segundos..."
sleep 5
"$EDITOR_CMD" "$CERT_FILE"
[[ -s "$CERT_FILE" ]] || { echo "Certificado vacío."; exit 1; }

echo "Pega Cloudflare Private Key (PEM) en 5 segundos..."
sleep 5
"$EDITOR_CMD" "$KEY_FILE"
[[ -s "$KEY_FILE" ]] || { echo "Clave privada vacía."; exit 1; }

echo
read -r -p "Usuario administrador inicial: " ADMIN_USER
read -r -s -p "Contraseña administrador inicial: " ADMIN_PASS
echo
read -r -p "Dominio público (ej: recargas.midominio.com): " PUBLIC_DOMAIN
read -r -p "Ruta pública de acceso [/recargas]: " BASE_PATH
BASE_PATH="${BASE_PATH:-/recargas}"

if [[ -z "$ADMIN_USER" || -z "$ADMIN_PASS" || -z "$PUBLIC_DOMAIN" ]]; then
  echo "Error: usuario, contraseña y dominio son obligatorios."
  exit 1
fi

SECRET="$(openssl rand -hex 32)"

cat > "$ENV_FILE" <<ENV
NODE_ENV=production
BIND_HOST=127.0.0.1
PORT=3000
PUBLIC_DOMAIN=$PUBLIC_DOMAIN
SECRET=$SECRET
BOOTSTRAP_ADMIN_USER=$ADMIN_USER
BOOTSTRAP_ADMIN_PASS=$ADMIN_PASS
DIRECT_TLS=false
SSL_CERT_PATH=$CERT_FILE
SSL_KEY_PATH=$KEY_FILE
ENV

cat > "$GATEWAY_ENV_FILE" <<ENV
GATEWAY_LISTEN_ADDR=:443
BASE_PATH=$BASE_PATH
UPSTREAM_URL=http://127.0.0.1:3000
SSL_CERT_PATH=$CERT_FILE
SSL_KEY_PATH=$KEY_FILE
ENV

chmod 600 "$ENV_FILE" "$GATEWAY_ENV_FILE" "$CERT_FILE" "$KEY_FILE"

cd "$ROOT_DIR"

command -v npm >/dev/null 2>&1 || { echo "npm no está instalado"; exit 1; }
command -v go >/dev/null 2>&1 || { echo "go no está instalado"; exit 1; }

echo "Instalando dependencias Node..."
npm install --omit=dev

echo "Compilando gateway Go..."
(cd gateway && go build -o "$ROOT_DIR/recargas-gateway" .)
chmod +x "$ROOT_DIR/recargas-gateway"

if command -v systemctl >/dev/null 2>&1; then
  echo "Configurando servicios systemd..."

  sudo bash -c "cat > '$APP_SERVICE_FILE'" <<SERVICE
[Unit]
Description=Recargas App (Node)
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

  sudo bash -c "cat > '$GW_SERVICE_FILE'" <<SERVICE
[Unit]
Description=Recargas Gateway (Go TLS 443)
After=network.target recargas-app.service
Requires=recargas-app.service

[Service]
Type=simple
WorkingDirectory=$ROOT_DIR
ExecStart=$ROOT_DIR/recargas-gateway
Restart=always
RestartSec=3
EnvironmentFile=$GATEWAY_ENV_FILE
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
  sudo systemctl enable recargas-app.service recargas-gateway.service
  sudo systemctl restart recargas-app.service recargas-gateway.service
  sudo systemctl status recargas-gateway.service --no-pager || true
else
  echo "systemctl no disponible. Inicia manualmente:"
  echo "1) npm start"
  echo "2) ./recargas-gateway"
fi

echo
echo "Instalación finalizada."
echo "Acceso público: https://$PUBLIC_DOMAIN$BASE_PATH"
echo "Admin inicial: $ADMIN_USER"
