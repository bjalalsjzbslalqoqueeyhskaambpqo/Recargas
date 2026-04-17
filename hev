#!/bin/bash
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

if [ "$(id -u)" -ne 0 ]; then error "Ejecutar como root."; exit 1; fi

info "Actualizando paquetes..."
apt-get update -qq
apt-get install -y -qq curl wget python3 python3-pip ca-certificates iproute2 unzip systemd

FRESH_INSTALL=true
if [ -f /opt/btserver/token.txt ] && systemctl is-active --quiet btserver 2>/dev/null; then
    FRESH_INSTALL=false
    warn "Instalación existente → modo ACTUALIZACIÓN"
else
    info "No se detectó instalación previa → modo INSTALACIÓN NUEVA"
fi

mkdir -p /opt/btserver

if [ -f /opt/btserver/token.txt ] && [ -s /opt/btserver/token.txt ]; then
    PANEL_TOKEN=$(cat /opt/btserver/token.txt)
    info "Token existente conservado."
else
    PANEL_TOKEN=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 64 || true)
    echo "${PANEL_TOKEN}" > /opt/btserver/token.txt
    chmod 600 /opt/btserver/token.txt
    info "Nuevo token generado."
fi

PANEL_PORT=8090
SERVER_IP=$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -1 || echo "0.0.0.0")

# ─────────────────────────────────────────────────────────────────────────────
# DROPBEAR — unit nativo systemd (Debian 11 solo trae init SysV, no unit real)
# ─────────────────────────────────────────────────────────────────────────────
info "Instalando dropbear..."
apt-get install -y dropbear

# Detectar binario (puede estar en /usr/sbin o /usr/bin según distro)
DROPBEAR_BIN=""
for p in /usr/sbin/dropbear /usr/bin/dropbear; do
    [ -x "$p" ] && { DROPBEAR_BIN="$p"; break; }
done
if [ -z "$DROPBEAR_BIN" ]; then
    error "No se encontró el binario de dropbear."; exit 1
fi
info "Dropbear binario: $DROPBEAR_BIN"

# Parar el servicio antes de reconfigurar
systemctl stop dropbear 2>/dev/null || true

# Deshabilitar el init SysV para que no compita con nuestro unit nativo
update-rc.d dropbear disable 2>/dev/null || true

# Marcar NO_START=1 en /etc/default/dropbear para que el init.d no arranque nada
cat > /etc/default/dropbear << 'DBEOF'
NO_START=1
DROPBEAR_PORT=2222
DROPBEAR_EXTRA_ARGS="-w -R"
DBEOF

# Eliminar el override.conf si quedó de versiones anteriores (era ignorado de todos modos)
rm -f /etc/systemd/system/dropbear.service.d/override.conf
rmdir /etc/systemd/system/dropbear.service.d 2>/dev/null || true

# Generar claves de host si no existen
mkdir -p /etc/dropbear
dropbearkey -t rsa    -f /etc/dropbear/dropbear_rsa_host_key    2>/dev/null || true
dropbearkey -t ecdsa  -f /etc/dropbear/dropbear_ecdsa_host_key  2>/dev/null || true
dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key 2>/dev/null || true

# Escribir unit nativo completo — tiene precedencia total sobre el generador SysV
# en /run/systemd/generator.late/, por lo que ya no aparece "is not a native service"
cat > /etc/systemd/system/dropbear.service << DBSVC
[Unit]
Description=Dropbear SSH server (127.0.0.1:2222)
After=network.target
Documentation=man:dropbear(8)

[Service]
ExecStart=${DROPBEAR_BIN} -F -E -p 127.0.0.1:2222 -w -R
Restart=on-failure
RestartSec=3
KillMode=process

[Install]
WantedBy=multi-user.target
DBSVC

systemctl daemon-reload
systemctl enable dropbear 2>/dev/null || true
info "Dropbear configurado en 127.0.0.1:2222 (unit nativo systemd, SysV deshabilitado)"

# ─────────────────────────────────────────────────────────────────────────────
# BADVPN-UDPGW — compilar desde source (el repo oficial no tiene binarios)
# ─────────────────────────────────────────────────────────────────────────────
UDPGW_PORT=7300
BADVPN_INSTALLED=false

if command -v badvpn-udpgw &>/dev/null; then
    info "badvpn-udpgw ya instalado — omitiendo compilación."
    BADVPN_INSTALLED=true
else
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "aarch64" ]; then
        info "Instalando dependencias para compilar badvpn..."
        apt-get install -y -qq cmake gcc make git 2>/dev/null || \
            apt-get install -y cmake gcc make git
        BADVPN_TMP=$(mktemp -d)
        info "Descargando badvpn desde source..."
        if git clone --depth=1 https://github.com/ambrop72/badvpn.git "$BADVPN_TMP/badvpn" 2>/dev/null; then
            mkdir -p "$BADVPN_TMP/build"
            cd "$BADVPN_TMP/build"
            if cmake "$BADVPN_TMP/badvpn" \
                    -DBUILD_NOTHING_BY_DEFAULT=1 \
                    -DBUILD_UDPGW=1 \
                    -DCMAKE_BUILD_TYPE=Release \
                    -DCMAKE_INSTALL_PREFIX=/usr/local \
                    2>/dev/null && make -j"$(nproc)" 2>/dev/null; then
                cp udpgw/badvpn-udpgw /usr/local/bin/badvpn-udpgw
                chmod +x /usr/local/bin/badvpn-udpgw
                BADVPN_INSTALLED=true
                info "badvpn-udpgw compilado e instalado correctamente."
            else
                warn "Falló la compilación de badvpn — omitiendo."
            fi
            cd - > /dev/null
        else
            warn "No se pudo clonar el repositorio de badvpn — omitiendo."
        fi
        rm -rf "$BADVPN_TMP"
    else
        warn "badvpn no soportado en arquitectura $ARCH — omitiendo."
    fi
fi

# Crear unit systemd para badvpn-udpgw si está disponible
if [ "$BADVPN_INSTALLED" = true ]; then
    cat > /etc/systemd/system/badvpn.service << BVSVC
[Unit]
Description=BadVPN UDP Gateway (puerto ${UDPGW_PORT})
After=network.target

[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:${UDPGW_PORT} --max-clients 500 --max-connections-for-client 10
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
BVSVC
    systemctl daemon-reload
    systemctl enable badvpn 2>/dev/null || true
fi

# ─────────────────────────────────────────────────────────────────────────────
# TUNNEL-ONLY SHELL
# ─────────────────────────────────────────────────────────────────────────────
cat > /usr/local/bin/tunnel-only << 'SHEOF'
#!/bin/bash
echo "Tunneling only. No shell access."
sleep 86400
SHEOF
chmod +x /usr/local/bin/tunnel-only
grep -qxF "/usr/local/bin/tunnel-only" /etc/shells || echo "/usr/local/bin/tunnel-only" >> /etc/shells

id -u sshtunnel &>/dev/null || useradd -r -s /usr/sbin/nologin -M sshtunnel 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# XRAY
# ─────────────────────────────────────────────────────────────────────────────
info "Instalando/actualizando Xray..."
if bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install; then
    info "Xray instalado correctamente."
else
    error "Falló la instalación de Xray."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# BBR
# ─────────────────────────────────────────────────────────────────────────────
info "Activando BBR..."
if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
    grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null || {
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    }
    sysctl -p -q 2>/dev/null || true
    info "BBR activado."
else
    warn "BBR no disponible en este kernel."
fi

# ─────────────────────────────────────────────────────────────────────────────
# XRAY CONFIG
# ─────────────────────────────────────────────────────────────────────────────
XRAY_CONFIG=/usr/local/etc/xray/config.json
mkdir -p "$(dirname "$XRAY_CONFIG")"

if [ "$FRESH_INSTALL" = true ] || [ ! -f "$XRAY_CONFIG" ]; then
    info "Escribiendo configuración de Xray..."
    cat > "$XRAY_CONFIG" << 'XEOF'
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": ["8.8.8.8", "1.1.1.1"],
    "queryStrategy": "UseIPv4"
  },
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 600,
        "uplinkOnly": 30,
        "downlinkOnly": 30,
        "bufferSize": 512
      }
    },
    "system": {
      "udpTimeout": 0,
      "connIdle": 600,
      "downlinkOnly": 30,
      "uplinkOnly": 30
    }
  },
  "inbounds": [
    {
      "port": 10809,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "a3482e88-686a-4a58-8126-99c9df64b7bf" }],
        "decryption": "none"
      },
      "streamSettings": { "network": "tcp", "security": "none" }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" },
      "streamSettings": {
        "sockopt": {
          "tcpFastOpen": true,
          "tcpCongestion": "bbr",
          "tcpKeepAliveInterval": 30,
          "tcpKeepAliveIdle": 60,
          "tcpUserTimeout": 10000
        }
      }
    }
  ]
}
XEOF
else
    warn "Config de Xray existente conservada."
fi

# ─────────────────────────────────────────────────────────────────────────────
# BTSERVER.PY
# ─────────────────────────────────────────────────────────────────────────────
info "Escribiendo btserver.py..."
cat > /opt/btserver/btserver.py << 'PYEOF'
#!/usr/bin/env python3
import asyncio, struct, time, json, threading
from pathlib import Path

TYPE_OPEN  = 0x01
TYPE_DATA  = 0x02
TYPE_CLOSE = 0x03

DB_PATH    = Path("/opt/btserver/clients.json")
DB_CACHE   = {}
DB_MTIME   = 0.0
ACTIVE_SESSIONS = {}

XRAY_HOST  = "127.0.0.1"
XRAY_PORT  = 10809
SSH_HOST   = "127.0.0.1"
SSH_PORT   = 2222

def load_db():
    global DB_CACHE, DB_MTIME
    if not DB_PATH.exists():
        return {}
    try:
        mtime = DB_PATH.stat().st_mtime
        if mtime == DB_MTIME and DB_CACHE:
            return DB_CACHE
        DB_CACHE = json.loads(DB_PATH.read_text())
        DB_MTIME = mtime
        return DB_CACHE
    except:
        return DB_CACHE

def ensure_client(client_id):
    db = load_db()
    item = db.get(client_id)
    now = int(time.time())
    if not item:
        return "UNKNOWN", 0, "", 0
    expires_at = int(item.get("expires_at", 0))
    name = str(item.get("name", "")).strip() or "sin-nombre"
    if now > expires_at:
        return "EXPIRED", 0, name, expires_at
    days_left = max(0, (expires_at - now + 86399) // 86400)
    return "VALID", days_left, name, expires_at

def expiry_checker():
    while True:
        now = time.time()
        tomorrow_2am = now - (now % 86400) + 86400 + 2 * 3600
        if tomorrow_2am - now > 86400:
            tomorrow_2am -= 86400
        time.sleep(max(1, tomorrow_2am - time.time()))
        db = load_db()
        now_int = int(time.time())
        expired = [cid for cid, w in list(ACTIVE_SESSIONS.items())
                   if int(db.get(cid, {}).get("expires_at", 0)) < now_int]
        for cid in expired:
            w = ACTIVE_SESSIONS.pop(cid, None)
            if w:
                try: w.close()
                except: pass
        time.sleep(1)

async def pipe(src_r, dst_w):
    try:
        while True:
            d = await src_r.read(65536)
            if not d:
                break
            dst_w.write(d)
            await dst_w.drain()
    except:
        pass
    try:
        dst_w.close()
    except:
        pass

async def handle_mux(reader, writer):
    streams = {}
    write_lock = asyncio.Lock()
    buf = bytearray()

    async def send_frame(t, sid, data=b""):
        async with write_lock:
            writer.write(struct.pack("!B I I", t, sid, len(data)) + data)
            await writer.drain()

    async def xray_to_client(sid, xr):
        try:
            while True:
                d = await xr.read(65536)
                if not d:
                    break
                await send_frame(TYPE_DATA, sid, d)
        except:
            pass
        await send_frame(TYPE_CLOSE, sid)
        streams.pop(sid, None)

    async def read_n(n):
        nonlocal buf
        while len(buf) < n:
            chunk = await reader.read(65536)
            if not chunk:
                raise ConnectionError()
            buf.extend(chunk)
        d, buf[:] = bytes(buf[:n]), buf[n:]
        return d

    try:
        while True:
            t, sid, l = struct.unpack("!B I I", await read_n(9))
            data = await read_n(l) if l else b""
            if t == TYPE_OPEN:
                try:
                    xr, xw = await asyncio.open_connection(XRAY_HOST, XRAY_PORT)
                    streams[sid] = (xr, xw)
                    asyncio.get_event_loop().create_task(xray_to_client(sid, xr))
                except:
                    await send_frame(TYPE_CLOSE, sid)
            elif t == TYPE_DATA:
                pair = streams.get(sid)
                if pair:
                    try:
                        pair[1].write(data)
                        await pair[1].drain()
                    except:
                        await send_frame(TYPE_CLOSE, sid)
                        streams.pop(sid, None)
            elif t == TYPE_CLOSE:
                pair = streams.pop(sid, None)
                if pair:
                    try:
                        pair[1].close()
                        await pair[1].wait_closed()
                    except:
                        pass
    except:
        pass
    finally:
        for _, (_, xw) in list(streams.items()):
            try:
                xw.close()
            except:
                pass
        try:
            writer.close()
        except:
            pass

async def handle(reader, writer):
    writer.transport.set_write_buffer_limits(high=65536, low=16384)
    raw = b""
    start = time.monotonic()
    while time.monotonic() - start < 5:
        try:
            chunk = await asyncio.wait_for(reader.read(4096), timeout=1)
            if not chunk:
                break
            raw += chunk
            if b"\r\n\r\n" in raw:
                break
        except asyncio.TimeoutError:
            break

    action = ""
    client_id = ""
    for line in raw.decode(errors="replace").splitlines():
        lower = line.lower().strip()
        if lower.startswith("action:") or lower.startswith("action :"):
            action = line.split(":", 1)[1].strip().lower()
        if lower.startswith("x-client-id:"):
            client_id = line.split(":", 1)[1].strip()

    async def reject(state, days=0):
        try:
            writer.write(
                f"HTTP/1.1 403 Forbidden\r\nConnection: close\r\n"
                f"X-Status: {state}\r\nX-Auth-State: {state}\r\nX-Days-Left: {days}\r\n\r\n"
                .encode()
            )
            await writer.drain()
            writer.close()
            await writer.wait_closed()
        except:
            pass

    if action == "ssh":
        try:
            writer.write(
                b"HTTP/1.1 101 Switching Protocols\r\n"
                b"Upgrade: websocket\r\nConnection: Upgrade\r\n"
                b"X-Status: VALID\r\nX-Auth-State: VALID\r\n\r\n"
            )
            await writer.drain()
            ssh_r, ssh_w = await asyncio.open_connection(SSH_HOST, SSH_PORT)
            await asyncio.gather(
                pipe(reader, ssh_w),
                pipe(ssh_r, writer)
            )
        except:
            pass
        finally:
            try:
                writer.close()
            except:
                pass
        return

    if not client_id:
        await reject("INVALID")
        return

    state, days_left, name, expires_at = ensure_client(client_id)
    if state != "VALID":
        await reject(state, days_left)
        return

    response = (
        b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        b"X-Status: VALID\r\nX-Auth-State: VALID\r\n"
        + f"X-Name: {name}\r\nX-Expire: {expires_at}\r\nX-Days-Left: {days_left}\r\n\r\n".encode()
    )

    if action in ("tunnel", "tunnel-fast"):
        writer.write(response)
        await writer.drain()
        prev = ACTIVE_SESSIONS.get(client_id)
        ACTIVE_SESSIONS[client_id] = writer
        if prev is not None:
            try:
                prev.close()
            except:
                pass
        try:
            await handle_mux(reader, writer)
        finally:
            if ACTIVE_SESSIONS.get(client_id) is writer:
                ACTIVE_SESSIONS.pop(client_id, None)
    elif action == "auth":
        writer.write(response)
        await writer.drain()
        try:
            writer.close()
            await writer.wait_closed()
        except:
            pass
    else:
        try:
            writer.close()
        except:
            pass

async def main():
    threading.Thread(target=expiry_checker, daemon=True).start()
    srv = await asyncio.start_server(handle, "0.0.0.0", 80, limit=65536, backlog=512)
    print("btserver escuchando :80  →  xray:10809 / dropbear:2222")
    async with srv:
        await srv.serve_forever()

if __name__ == "__main__":
    asyncio.run(main())
PYEOF
chmod +x /opt/btserver/btserver.py

# ─────────────────────────────────────────────────────────────────────────────
# PANEL.PY
# ─────────────────────────────────────────────────────────────────────────────
info "Escribiendo panel.py..."
cat > /opt/btserver/panel.py << PYEOF
#!/usr/bin/env python3
import json
import subprocess
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

DB_PATH      = Path("/opt/btserver/clients.json")
SSH_DB_PATH  = Path("/opt/btserver/ssh_users.json")
TOKEN_PATH   = Path("/opt/btserver/token.txt")
PORT         = ${PANEL_PORT}
TUNNEL_SHELL = "/usr/local/bin/tunnel-only"

def load_token():
    return TOKEN_PATH.read_text().strip()

def load_db():
    if not DB_PATH.exists():
        DB_PATH.write_text("{}")
    try:
        return json.loads(DB_PATH.read_text())
    except:
        return {}

def save_db(db):
    DB_PATH.write_text(json.dumps(db, indent=2, sort_keys=True))

def load_ssh_db():
    if not SSH_DB_PATH.exists():
        SSH_DB_PATH.write_text("{}")
    try:
        return json.loads(SSH_DB_PATH.read_text())
    except:
        return {}

def save_ssh_db(db):
    SSH_DB_PATH.write_text(json.dumps(db, indent=2, sort_keys=True))

def now_ts():
    return int(time.time())

def days_left(expires_at):
    return max(0, (int(expires_at) - now_ts() + 86399) // 86400)

def json_resp(handler, code, data):
    body = json.dumps(data, ensure_ascii=False).encode()
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)

def ensure_tunnel_shell():
    p = Path(TUNNEL_SHELL)
    if not p.exists():
        p.write_text("#!/bin/bash\necho 'Tunneling only. No shell access.'\nsleep 86400\n")
        p.chmod(0o755)
    try:
        shells = Path("/etc/shells").read_text()
    except:
        shells = ""
    if TUNNEL_SHELL not in shells:
        with open("/etc/shells", "a") as f:
            f.write(TUNNEL_SHELL + "\n")

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args): pass

    def auth(self):
        return self.headers.get("X-Token", "").strip() == load_token()

    def read_body(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length == 0:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode())
        except:
            return {}

    def do_GET(self):
        if not self.auth():
            json_resp(self, 401, {"error": "unauthorized"}); return
        parsed = urlparse(self.path)
        path   = parsed.path.rstrip("/")
        params = parse_qs(parsed.query)

        if path == "/clients":
            db = load_db()
            result = []
            for cid, data in sorted(db.items()):
                exp = int(data.get("expires_at", 0))
                result.append({"id": cid, "name": data.get("name", "sin-nombre"),
                    "expires_at": exp, "days_left": days_left(exp), "active": now_ts() <= exp})
            json_resp(self, 200, {"clients": result, "total": len(result)}); return

        if path == "/client":
            cid = params.get("id", [""])[0].strip()
            if not cid:
                json_resp(self, 400, {"error": "falta id"}); return
            db   = load_db()
            item = db.get(cid)
            if not item:
                json_resp(self, 404, {"error": "no encontrado"}); return
            exp = int(item.get("expires_at", 0))
            json_resp(self, 200, {"id": cid, "name": item.get("name", "sin-nombre"),
                "expires_at": exp, "days_left": days_left(exp), "active": now_ts() <= exp}); return

        if path == "/ssh/users":
            db = load_ssh_db()
            result = []
            for user, data in sorted(db.items()):
                exp = int(data.get("expires_at", 0))
                result.append({"user": user, "name": data.get("name", user),
                    "expires_at": exp, "days_left": days_left(exp), "active": now_ts() <= exp})
            json_resp(self, 200, {"users": result, "total": len(result)}); return

        json_resp(self, 404, {"error": "ruta no encontrada"})

    def do_POST(self):
        if not self.auth():
            json_resp(self, 401, {"error": "unauthorized"}); return
        parsed = urlparse(self.path)
        path   = parsed.path.rstrip("/")
        body   = self.read_body()

        if path == "/client/create":
            cid  = str(body.get("id", "")).strip()
            name = str(body.get("name", "sin-nombre")).strip() or "sin-nombre"
            days = int(body.get("days", 30))
            if not cid:
                json_resp(self, 400, {"error": "falta id"}); return
            db  = load_db()
            now = now_ts()
            db[cid] = {"name": name, "created_at": db.get(cid, {}).get("created_at", now),
                "expires_at": now + max(days, 0) * 86400}
            save_db(db)
            json_resp(self, 200, {"ok": True, "id": cid, "name": name, "days": days}); return

        if path == "/client/delete":
            cid = str(body.get("id", "")).strip()
            if not cid:
                json_resp(self, 400, {"error": "falta id"}); return
            db = load_db()
            if cid not in db:
                json_resp(self, 404, {"error": "no encontrado"}); return
            db.pop(cid); save_db(db)
            json_resp(self, 200, {"ok": True}); return

        if path == "/client/update":
            cid = str(body.get("id", "")).strip()
            if not cid:
                json_resp(self, 400, {"error": "falta id"}); return
            db   = load_db()
            item = db.get(cid)
            if not item:
                json_resp(self, 404, {"error": "no encontrado"}); return
            if "name" in body:
                item["name"] = str(body["name"]).strip() or "sin-nombre"
            base_exp = int(item.get("expires_at", now_ts()))
            base     = base_exp if base_exp > now_ts() else now_ts()
            if "add_days" in body:
                item["expires_at"] = base + max(int(body["add_days"]), 0) * 86400
            elif "sub_days" in body:
                item["expires_at"] = max(0, base_exp - max(int(body["sub_days"]), 0) * 86400)
            elif "set_days" in body:
                item["expires_at"] = now_ts() + max(int(body["set_days"]), 0) * 86400
            new_id = str(body.get("new_id", "")).strip()
            if new_id and new_id != cid:
                db.pop(cid); db[new_id] = item; cid = new_id
            else:
                db[cid] = item
            save_db(db)
            exp = int(item.get("expires_at", 0))
            json_resp(self, 200, {"ok": True, "id": cid, "name": item.get("name"),
                "days_left": days_left(exp)}); return

        if path == "/ssh/create":
            user     = str(body.get("user", "")).strip()
            password = str(body.get("password", "")).strip()
            name     = str(body.get("name", user)).strip() or user
            days     = int(body.get("days", 30))
            if not user or not password:
                json_resp(self, 400, {"error": "falta user o password"}); return

            ensure_tunnel_shell()

            existing = subprocess.run(["id", user], capture_output=True)
            if existing.returncode != 0:
                r = subprocess.run(
                    ["useradd", "-s", TUNNEL_SHELL, "-M", "-p", "!", user],
                    capture_output=True, text=True
                )
                if r.returncode != 0:
                    json_resp(self, 500, {"error": f"useradd fallo: {r.stderr.strip()}"}); return
            else:
                subprocess.run(["usermod", "-s", TUNNEL_SHELL, user], capture_output=True)

            p = subprocess.run(
                ["chpasswd"],
                input=f"{user}:{password}",
                capture_output=True, text=True
            )
            if p.returncode != 0:
                json_resp(self, 500, {"error": f"chpasswd fallo: {p.stderr.strip()}"}); return

            db  = load_ssh_db()
            now = now_ts()
            db[user] = {"name": name, "created_at": db.get(user, {}).get("created_at", now),
                "expires_at": now + max(days, 0) * 86400}
            save_ssh_db(db)
            json_resp(self, 200, {"ok": True, "user": user, "name": name, "days": days}); return

        if path == "/ssh/delete":
            user = str(body.get("user", "")).strip()
            if not user:
                json_resp(self, 400, {"error": "falta user"}); return
            db = load_ssh_db()
            if user not in db:
                json_resp(self, 404, {"error": "no encontrado"}); return
            subprocess.run(["userdel", user], capture_output=True)
            db.pop(user); save_ssh_db(db)
            json_resp(self, 200, {"ok": True}); return

        if path == "/ssh/update":
            user = str(body.get("user", "")).strip()
            if not user:
                json_resp(self, 400, {"error": "falta user"}); return
            db   = load_ssh_db()
            item = db.get(user)
            if not item:
                json_resp(self, 404, {"error": "no encontrado"}); return
            if "name" in body:
                item["name"] = str(body["name"]).strip() or user
            if "password" in body:
                new_pass = str(body["password"]).strip()
                if new_pass:
                    subprocess.run(["chpasswd"], input=f"{user}:{new_pass}",
                        capture_output=True, text=True)
            base_exp = int(item.get("expires_at", now_ts()))
            base     = base_exp if base_exp > now_ts() else now_ts()
            if "add_days" in body:
                item["expires_at"] = base + max(int(body["add_days"]), 0) * 86400
            elif "sub_days" in body:
                item["expires_at"] = max(0, base_exp - max(int(body["sub_days"]), 0) * 86400)
            elif "set_days" in body:
                item["expires_at"] = now_ts() + max(int(body["set_days"]), 0) * 86400
            db[user] = item
            save_ssh_db(db)
            exp = int(item.get("expires_at", 0))
            json_resp(self, 200, {"ok": True, "user": user, "days_left": days_left(exp)}); return

        json_resp(self, 404, {"error": "ruta no encontrada"})

if __name__ == "__main__":
    print(f"btpanel escuchando :{PORT}")
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
PYEOF
chmod +x /opt/btserver/panel.py

# ─────────────────────────────────────────────────────────────────────────────
# SYSTEMD UNITS — btserver y btpanel
# ─────────────────────────────────────────────────────────────────────────────
cat > /etc/systemd/system/btserver.service << 'SVCEOF'
[Unit]
Description=BlackTunnel Server
After=network.target xray.service dropbear.service

[Service]
ExecStart=/usr/bin/python3 /opt/btserver/btserver.py
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

cat > /etc/systemd/system/btpanel.service << 'SVCEOF'
[Unit]
Description=BlackTunnel Panel API
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/btserver/panel.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload

# Habilitar servicios base siempre
systemctl enable xray btserver btpanel dropbear 2>/dev/null || true

# Habilitar badvpn solo si se instaló
if [ "$BADVPN_INSTALLED" = true ]; then
    systemctl enable badvpn 2>/dev/null || true
fi

# ─────────────────────────────────────────────────────────────────────────────
# ARRANQUE FINAL
# ─────────────────────────────────────────────────────────────────────────────
info "Iniciando servicios..."
for svc in xray dropbear btserver btpanel; do
    if systemctl restart "$svc" 2>/dev/null; then
        info "  ✓ $svc OK"
    else
        warn "  ✗ $svc falló — revisa: journalctl -u $svc -n 30"
    fi
done

if [ "$BADVPN_INSTALLED" = true ]; then
    if systemctl restart badvpn 2>/dev/null; then
        info "  ✓ badvpn OK"
    else
        warn "  ✗ badvpn falló — revisa: journalctl -u badvpn -n 30"
    fi
fi

echo ""
echo "================================================"
[ "$FRESH_INSTALL" = true ] && echo "  INSTALACION COMPLETA" || echo "  ACTUALIZACION COMPLETA"
echo "================================================"
echo ""
echo "  URL PANEL:  http://${SERVER_IP}:${PANEL_PORT}"
echo "  TOKEN:      ${PANEL_TOKEN}"
echo "  BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'no disponible')"
echo "  BADVPN UDP: $([ "$BADVPN_INSTALLED" = true ] && echo "127.0.0.1:${UDPGW_PORT}" || echo "no instalado")"
echo ""
echo "  Flujo:  cliente:80 → btserver.py"
echo "            action:ssh    → dropbear 127.0.0.1:2222"
echo "            action:tunnel → xray     127.0.0.1:10809"
echo "            udp/icmp      → badvpn   127.0.0.1:${UDPGW_PORT}"
echo "================================================"
