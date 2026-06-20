#!/usr/bin/env bash
# install_streamserver.sh
# Instalador completo: Go + yt-dlp + ffmpeg + servidor de streaming/lobby
# Uso: sudo bash install_streamserver.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: corre esto con sudo/root. Uso: sudo bash install_streamserver.sh"
  exit 1
fi

GO_VERSION="1.22.5"
INSTALL_DIR="/opt/streamserver"
SRC_DIR="${INSTALL_DIR}/src"
CACHE_ROOT="/root/dvr_cache"
DATA_FILE="${INSTALL_DIR}/library.json"
SERVICE_NAME="streamserver"
HTTP_PORT="8383"
LOBBY_PORT="8384"
ADMIN_TOKEN_FILE="${INSTALL_DIR}/admin_token.txt"

echo "=================================================="
echo "  Instalando Stream Server (Go) + dependencias"
echo "=================================================="

# ------------------------------------------------------------------
# 1. Dependencias del sistema
# ------------------------------------------------------------------
echo
echo "[1/6] Paquetes del sistema..."
apt-get update -qq
apt-get install -y -qq curl wget tar python3 python3-pip ffmpeg jq >/dev/null

# ------------------------------------------------------------------
# 2. yt-dlp
# ------------------------------------------------------------------
echo
echo "[2/6] Instalando/actualizando yt-dlp..."
PIP_HELP="$(python3 -m pip install --help || true)"
if echo "$PIP_HELP" | grep -q -- "--break-system-packages"; then
  python3 -m pip install --upgrade yt-dlp --break-system-packages -q
else
  python3 -m pip install --upgrade yt-dlp -q
fi
echo "      yt-dlp: $(yt-dlp --version 2>/dev/null || echo 'instalado')"

# ------------------------------------------------------------------
# 3. Go (toolchain)
# ------------------------------------------------------------------
echo
echo "[3/6] Instalando Go ${GO_VERSION}..."
if command -v go >/dev/null 2>&1 && go version | grep -q "${GO_VERSION}"; then
  echo "      Go ${GO_VERSION} ya está instalado."
else
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) GOARCH="amd64" ;;
    aarch64) GOARCH="arm64" ;;
    *) echo "ERROR: arquitectura no soportada: $ARCH"; exit 1 ;;
  esac
  GO_TARBALL="go${GO_VERSION}.linux-${GOARCH}.tar.gz"
  cd /tmp
  wget -q "https://go.dev/dl/${GO_TARBALL}" -O "${GO_TARBALL}"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "${GO_TARBALL}"
  rm -f "${GO_TARBALL}"
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
fi
export PATH="/usr/local/go/bin:${PATH}"
echo "      $(go version)"

# ------------------------------------------------------------------
# 4. Activar BBR (igual que el script anterior, mejora ancho de banda real)
# ------------------------------------------------------------------
echo
echo "[4/6] Activando BBR..."
CURRENT_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '')"
if [ "$CURRENT_CC" = "bbr" ]; then
  echo "      BBR ya estaba activo."
else
  modprobe tcp_bbr 2>/dev/null || true
  cat > /etc/sysctl.d/99-streamserver-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl -p /etc/sysctl.d/99-streamserver-bbr.conf >/dev/null 2>&1 || true
  NEW_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '')"
  if [ "$NEW_CC" = "bbr" ]; then
    echo "      BBR activado correctamente."
  else
    echo "      AVISO: no se pudo confirmar BBR (kernel >= 4.9 requerido)."
  fi
fi

# ------------------------------------------------------------------
# 5. Generar el código fuente Go del servidor
# ------------------------------------------------------------------
echo
echo "[5/6] Generando código fuente del servidor..."
mkdir -p "${SRC_DIR}"
mkdir -p "${CACHE_ROOT}"

cat > "${SRC_DIR}/go.mod" <<'EOF'
module streamserver

go 1.22
EOF

cat > "${SRC_DIR}/main.go" <<'GOEOF'
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
)

// ============================================================
// Configuración
// ============================================================

const (
	httpPort     = "8383"
	lobbyPort    = "8384"
	cacheRoot    = "/root/dvr_cache"
	dataFile     = "/opt/streamserver/library.json"
	adminTokenFP = "/opt/streamserver/admin_token.txt"
	resolveTimeoutSec = 30
)

var qualities = map[string]string{
	"480": "best[height<=480]",
	"720": "best[height<=720]",
}

// ============================================================
// Modelo de datos
// ============================================================

type ContentItem struct {
	ID              string  `json:"id"`
	Name            string  `json:"name,omitempty"`
	URL             string  `json:"url,omitempty"`
	Thumbnail       *string `json:"thumbnail,omitempty"`
	DurationSeconds *int    `json:"duration_seconds,omitempty"`
	IsLive          bool    `json:"is_live,omitempty"`
	Status          string  `json:"status"` // processing | ready | failed

	// Internos, no se serializan al cliente Android (json:"-")
	Mode          string            `json:"-"` // manual | library | live
	SourceURL     string            `json:"-"` // URL original pasada por el admin
	QualityURLs   map[string]string `json:"-"` // calidad -> ruta servible
	QualityReady  map[string]bool   `json:"-"`
}

type Library struct {
	mu    sync.RWMutex
	items map[string]*ContentItem
}

func NewLibrary() *Library {
	return &Library{items: make(map[string]*ContentItem)}
}

func (l *Library) Add(item *ContentItem) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.items[item.ID] = item
}

func (l *Library) Get(id string) (*ContentItem, bool) {
	l.mu.RLock()
	defer l.mu.RUnlock()
	it, ok := l.items[id]
	return it, ok
}

func (l *Library) ListForClient() []ContentItem {
	l.mu.RLock()
	defer l.mu.RUnlock()
	out := make([]ContentItem, 0, len(l.items))
	for _, it := range l.items {
		// Copia plana solo con los campos que viajan al cliente.
		out = append(out, ContentItem{
			ID:              it.ID,
			Name:            it.Name,
			URL:             it.URL,
			Thumbnail:       it.Thumbnail,
			DurationSeconds: it.DurationSeconds,
			IsLive:          it.IsLive,
			Status:          it.Status,
		})
	}
	return out
}

func (l *Library) Save() error {
	l.mu.RLock()
	defer l.mu.RUnlock()
	tmp := dataFile + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	all := make([]*ContentItem, 0, len(l.items))
	for _, it := range l.items {
		all = append(all, it)
	}
	if err := enc.Encode(all); err != nil {
		f.Close()
		return err
	}
	f.Close()
	return os.Rename(tmp, dataFile)
}

func (l *Library) Load() error {
	data, err := os.ReadFile(dataFile)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	var all []*ContentItem
	if err := json.Unmarshal(data, &all); err != nil {
		return err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, it := range all {
		if it.QualityURLs == nil {
			it.QualityURLs = make(map[string]string)
		}
		if it.QualityReady == nil {
			it.QualityReady = make(map[string]bool)
		}
		l.items[it.ID] = it
	}
	return nil
}

// ============================================================
// Notificación a clientes de lobby conectados (broadcast de content_list)
// ============================================================

type LobbyHub struct {
	mu      sync.Mutex
	clients map[string]*LobbyClient
}

type LobbyClient struct {
	deviceID string
	writer   *bufio.Writer
	mu       sync.Mutex // protege escrituras concurrentes al mismo conn
}

func NewLobbyHub() *LobbyHub {
	return &LobbyHub{clients: make(map[string]*LobbyClient)}
}

func (h *LobbyHub) Register(c *LobbyClient) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.clients[c.deviceID] = c
}

func (h *LobbyHub) Unregister(deviceID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.clients, deviceID)
}

func (h *LobbyHub) BroadcastContentList(lib *Library) {
	msg := map[string]interface{}{
		"type":  "content_list",
		"items": lib.ListForClient(),
	}
	data, _ := json.Marshal(msg)
	line := append(data, '\n')

	h.mu.Lock()
	defer h.mu.Unlock()
	for id, c := range h.clients {
		c.mu.Lock()
		_, err := c.writer.Write(line)
		if err == nil {
			err = c.writer.Flush()
		}
		c.mu.Unlock()
		if err != nil {
			log.Printf("[lobby] error escribiendo a %s, se desconecta: %v", id, err)
			delete(h.clients, id)
		}
	}
}

// ============================================================
// yt-dlp helpers
// ============================================================

func resolveQualityURL(pageURL, format string) (string, error) {
	ctx := exec.Command("yt-dlp", "-g", "--no-playlist", "--quiet", "-f", format, pageURL)
	var out bytes.Buffer
	var errOut bytes.Buffer
	ctx.Stdout = &out
	ctx.Stderr = &errOut

	done := make(chan error, 1)
	if err := ctx.Start(); err != nil {
		return "", err
	}
	go func() { done <- ctx.Wait() }()

	select {
	case err := <-done:
		if err != nil {
			return "", fmt.Errorf("yt-dlp: %v (%s)", err, strings.TrimSpace(errOut.String()))
		}
	case <-time.After(resolveTimeoutSec * time.Second):
		_ = ctx.Process.Kill()
		return "", fmt.Errorf("yt-dlp timeout resolviendo %s", format)
	}

	line := strings.TrimSpace(out.String())
	if line == "" {
		return "", fmt.Errorf("yt-dlp no devolvió URL")
	}
	// puede devolver varias líneas (audio+video separados); tomamos la primera
	return strings.Split(line, "\n")[0], nil
}

type ytDlpMeta struct {
	Duration  float64 `json:"duration"`
	Thumbnail string  `json:"thumbnail"`
}

func resolveMetadata(pageURL string) (*ytDlpMeta, error) {
	ctx := exec.Command("yt-dlp", "--no-playlist", "--quiet", "--dump-json", pageURL)
	var out bytes.Buffer
	ctx.Stdout = &out
	if err := ctx.Run(); err != nil {
		return nil, err
	}
	var meta ytDlpMeta
	if err := json.Unmarshal(out.Bytes(), &meta); err != nil {
		return nil, err
	}
	return &meta, nil
}

func downloadToFile(url, dest string) error {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
	client := &http.Client{Timeout: 0} // descargas pueden ser largas
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("status %d descargando %s", resp.StatusCode, url)
	}
	f, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(f, resp.Body)
	return err
}

// ============================================================
// Modo: biblioteca automática (descarga ambas calidades a disco)
// ============================================================

func processLibraryItem(lib *Library, hub *LobbyHub, item *ContentItem) {
	itemDir := filepath.Join(cacheRoot, item.ID)
	if err := os.MkdirAll(itemDir, 0o755); err != nil {
		log.Printf("[library] mkdir error: %v", err)
		item.Status = "failed"
		lib.Save()
		hub.BroadcastContentList(lib)
		return
	}

	meta, err := resolveMetadata(item.SourceURL)
	if err == nil && meta != nil {
		if meta.Duration > 0 {
			d := int(meta.Duration)
			item.DurationSeconds = &d
		}
		if meta.Thumbnail != "" {
			t := meta.Thumbnail
			item.Thumbnail = &t
		}
	} else {
		log.Printf("[library] no se pudo obtener metadata de %s: %v", item.SourceURL, err)
	}

	var wg sync.WaitGroup
	var anyReady bool
	var mu sync.Mutex

	for quality, format := range qualities {
		wg.Add(1)
		go func(quality, format string) {
			defer wg.Done()
			resolved, err := resolveQualityURL(item.SourceURL, format)
			if err != nil {
				log.Printf("[library][%s] no se pudo resolver %s: %v", item.ID, quality, err)
				return
			}
			dest := filepath.Join(itemDir, quality+".mp4")
			if err := downloadToFile(resolved, dest); err != nil {
				log.Printf("[library][%s] no se pudo descargar %s: %v", item.ID, quality, err)
				return
			}
			mu.Lock()
			item.QualityURLs[quality] = dest
			item.QualityReady[quality] = true
			anyReady = true
			mu.Unlock()
			log.Printf("[library][%s] calidad %s lista", item.ID, quality)
		}(quality, format)
	}
	wg.Wait()

	if anyReady {
		// Servimos la calidad más alta disponible como URL principal del item.
		if u, ok := item.QualityURLs["720"]; ok {
			item.URL = "/content/" + item.ID + "/720"
			_ = u
		} else if u, ok := item.QualityURLs["480"]; ok {
			item.URL = "/content/" + item.ID + "/480"
			_ = u
		}
		item.Status = "ready"
	} else {
		item.Status = "failed"
	}
	lib.Save()
	hub.BroadcastContentList(lib)
}

// ============================================================
// Modo: en vivo (proceso yt-dlp compartido entre todos los viewers)
// ============================================================

type LiveSession struct {
	mu       sync.Mutex
	cmd      *exec.Cmd
	stdout   io.ReadCloser
	clients  map[chan []byte]bool
	started  bool
}

type LiveManager struct {
	mu       sync.Mutex
	sessions map[string]*LiveSession
}

func NewLiveManager() *LiveManager {
	return &LiveManager{sessions: make(map[string]*LiveSession)}
}

func (m *LiveManager) join(contentID, sourceURL string) (*LiveSession, chan []byte, error) {
	m.mu.Lock()
	sess, exists := m.sessions[contentID]
	if !exists {
		sess = &LiveSession{clients: make(map[chan []byte]bool)}
		m.sessions[contentID] = sess
	}
	m.mu.Unlock()

	sess.mu.Lock()
	defer sess.mu.Unlock()

	ch := make(chan []byte, 64)
	sess.clients[ch] = true

	if !sess.started {
		cmd := exec.Command("yt-dlp", "--no-playlist", "--quiet", "-o", "-", sourceURL)
		stdout, err := cmd.StdoutPipe()
		if err != nil {
			delete(sess.clients, ch)
			return nil, nil, err
		}
		if err := cmd.Start(); err != nil {
			delete(sess.clients, ch)
			return nil, nil, err
		}
		sess.cmd = cmd
		sess.stdout = stdout
		sess.started = true

		go func() {
			buf := make([]byte, 64*1024)
			for {
				n, err := stdout.Read(buf)
				if n > 0 {
					chunk := make([]byte, n)
					copy(chunk, buf[:n])
					sess.mu.Lock()
					for c := range sess.clients {
						select {
						case c <- chunk:
						default:
							// cliente lento: descartamos el chunk para él, no bloqueamos al resto
						}
					}
					sess.mu.Unlock()
				}
				if err != nil {
					sess.mu.Lock()
					for c := range sess.clients {
						close(c)
					}
					sess.clients = make(map[chan []byte]bool)
					sess.mu.Unlock()
					m.mu.Lock()
					delete(m.sessions, contentID)
					m.mu.Unlock()
					return
				}
			}
		}()
	}

	return sess, ch, nil
}

func (m *LiveManager) leave(contentID string, sess *LiveSession, ch chan []byte) {
	sess.mu.Lock()
	delete(sess.clients, ch)
	remaining := len(sess.clients)
	sess.mu.Unlock()

	if remaining == 0 {
		m.mu.Lock()
		delete(m.sessions, contentID)
		m.mu.Unlock()
		if sess.cmd != nil && sess.cmd.Process != nil {
			_ = sess.cmd.Process.Kill()
			log.Printf("[live][%s] sin viewers, proceso yt-dlp detenido", contentID)
		}
	}
}

// ============================================================
// HTTP: servidor de streaming
// ============================================================

func startHTTPServer(lib *Library, live *LiveManager) {
	mux := http.NewServeMux()

	mux.HandleFunc("/content/", func(w http.ResponseWriter, r *http.Request) {
		// /content/{id}/{quality}
		parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/content/"), "/")
		if len(parts) != 2 {
			http.NotFound(w, r)
			return
		}
		id, quality := parts[0], parts[1]
		item, ok := lib.Get(id)
		if !ok {
			http.NotFound(w, r)
			return
		}
		path, ok := item.QualityURLs[quality]
		if !ok {
			http.Error(w, "calidad no disponible", http.StatusNotFound)
			return
		}
		w.Header().Set("Access-Control-Allow-Origin", "*")
		http.ServeFile(w, r, path)
	})

	mux.HandleFunc("/live/", func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.URL.Path, "/live/")
		item, ok := lib.Get(id)
		if !ok || !item.IsLive {
			http.NotFound(w, r)
			return
		}
		sess, ch, err := live.join(id, item.SourceURL)
		if err != nil {
			http.Error(w, "no se pudo iniciar el stream en vivo", http.StatusBadGateway)
			return
		}
		defer live.leave(id, sess, ch)

		w.Header().Set("Content-Type", "video/mp2t")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Cache-Control", "no-cache")
		flusher, _ := w.(http.Flusher)

		for chunk := range ch {
			if _, err := w.Write(chunk); err != nil {
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
	})

	mux.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(lib.ListForClient())
	})

	srv := &http.Server{Addr: ":" + httpPort, Handler: mux}
	log.Printf("[http] sirviendo contenido en :%s", httpPort)
	log.Fatal(srv.ListenAndServe())
}

// ============================================================
// Lobby: handshake HTTP -> 101 + JSON por línea
// ============================================================

func startLobbyServer(lib *Library, hub *LobbyHub) {
	ln, err := net.Listen("tcp", ":"+lobbyPort)
	if err != nil {
		log.Fatalf("[lobby] no se pudo escuchar en :%s: %v", lobbyPort, err)
	}
	log.Printf("[lobby] escuchando conexiones en :%s", lobbyPort)

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("[lobby] accept error: %v", err)
			continue
		}
		go handleLobbyConn(conn, lib, hub)
	}
}

func handleLobbyConn(conn net.Conn, lib *Library, hub *LobbyHub) {
	defer conn.Close()
	reader := bufio.NewReader(conn)

	// --- Leer request HTTP de upgrade (líneas hasta línea vacía) ---
	headers := make(map[string]string)
	requestLine, err := reader.ReadString('\n')
	if err != nil {
		return
	}
	if !strings.HasPrefix(requestLine, "GET ") {
		conn.Write([]byte("HTTP/1.1 400 Bad Request\r\n\r\n"))
		return
	}
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			return
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			break
		}
		kv := strings.SplitN(line, ":", 2)
		if len(kv) == 2 {
			headers[strings.TrimSpace(strings.ToLower(kv[0]))] = strings.TrimSpace(kv[1])
		}
	}

	deviceID := headers["x-device-id"]
	if deviceID == "" {
		conn.Write([]byte("HTTP/1.1 400 Bad Request\r\n\r\nmissing X-Device-Id\r\n"))
		return
	}

	// --- Responder 101 ---
	resp := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Connection: Upgrade\r\n" +
		"Upgrade: websocket\r\n\r\n"
	if _, err := conn.Write([]byte(resp)); err != nil {
		return
	}

	writer := bufio.NewWriter(conn)
	client := &LobbyClient{deviceID: deviceID, writer: writer}
	hub.Register(client)
	defer hub.Unregister(deviceID)

	log.Printf("[lobby] dispositivo conectado: %s", deviceID)

	// Modo simple/prueba: aceptamos a todos sin aprobación, estado siempre "ready".
	sendLine(client, map[string]interface{}{"type": "state", "status": "ready"})
	sendLine(client, map[string]interface{}{
		"type":  "content_list",
		"items": lib.ListForClient(),
	})

	// --- Loop de lectura de mensajes entrantes ---
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			log.Printf("[lobby] %s desconectado: %v", deviceID, err)
			return
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var msg map[string]interface{}
		if err := json.Unmarshal([]byte(line), &msg); err != nil {
			continue
		}
		msgType, _ := msg["type"].(string)
		switch msgType {
		case "hello":
			// ya identificamos por header; nada más que hacer en modo simple.
		case "play":
			contentID, _ := msg["content_id"].(string)
			log.Printf("[lobby] %s pidio reproducir: %s", deviceID, contentID)
		}
	}
}

func sendLine(c *LobbyClient, v interface{}) {
	data, _ := json.Marshal(v)
	c.mu.Lock()
	defer c.mu.Unlock()
	c.writer.Write(data)
	c.writer.Write([]byte("\n"))
	c.writer.Flush()
}

// ============================================================
// CLI de administración (comandos locales, vía argumentos)
// ============================================================

func cliAddManual(lib *Library, hub *LobbyHub, name, url string, durationSec int) {
	id := uuid.NewString()
	item := &ContentItem{
		ID:     id,
		Name:   name,
		URL:    url,
		Status: "ready",
		Mode:   "manual",
	}
	if durationSec > 0 {
		item.DurationSeconds = &durationSec
	}
	lib.Add(item)
	lib.Save()
	hub.BroadcastContentList(lib)
	fmt.Printf("OK: agregado modo manual, id=%s\n", id)
}

func cliAddLibrary(lib *Library, hub *LobbyHub, name, sourceURL string) {
	id := uuid.NewString()
	item := &ContentItem{
		ID:           id,
		Name:         name,
		SourceURL:    sourceURL,
		Status:       "processing",
		Mode:         "library",
		QualityURLs:  make(map[string]string),
		QualityReady: make(map[string]bool),
	}
	lib.Add(item)
	lib.Save()
	hub.BroadcastContentList(lib)
	fmt.Printf("OK: agregado modo biblioteca (procesando en background), id=%s\n", id)
	go processLibraryItem(lib, hub, item)
}

func cliAddLive(lib *Library, hub *LobbyHub, name, sourceURL string) {
	id := uuid.NewString()
	item := &ContentItem{
		ID:        id,
		Name:      name,
		SourceURL: sourceURL,
		URL:       "/live/" + id,
		Status:    "ready",
		Mode:      "live",
		IsLive:    true,
	}
	lib.Add(item)
	lib.Save()
	hub.BroadcastContentList(lib)
	fmt.Printf("OK: agregado modo en vivo, id=%s\n", id)
}

func cliList(lib *Library) {
	items := lib.ListForClient()
	for _, it := range items {
		live := ""
		if it.IsLive {
			live = " [EN VIVO]"
		}
		fmt.Printf("- %s | %s | %s%s\n", it.ID, it.Name, it.Status, live)
	}
}

// ============================================================
// main
// ============================================================

func main() {
	lib := NewLibrary()
	if err := lib.Load(); err != nil {
		log.Printf("[main] aviso: no se pudo cargar biblioteca previa: %v", err)
	}
	hub := NewLobbyHub()
	live := NewLiveManager()

	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "add-manual":
			fs := os.Args[2:]
			if len(fs) < 2 {
				fmt.Println("Uso: streamserver add-manual <nombre> <url> [duracion_segundos]")
				os.Exit(1)
			}
			dur := 0
			if len(fs) > 2 {
				dur, _ = strconv.Atoi(fs[2])
			}
			cliAddManual(lib, hub, fs[0], fs[1], dur)
			return
		case "add-library":
			fs := os.Args[2:]
			if len(fs) < 2 {
				fmt.Println("Uso: streamserver add-library <nombre> <url-origen>")
				os.Exit(1)
			}
			cliAddLibrary(lib, hub, fs[0], fs[1])
			return
		case "add-live":
			fs := os.Args[2:]
			if len(fs) < 2 {
				fmt.Println("Uso: streamserver add-live <nombre> <url-origen>")
				os.Exit(1)
			}
			cliAddLive(lib, hub, fs[0], fs[1])
			return
		case "list":
			cliList(lib)
			return
		case "serve":
			// sigue abajo
		default:
			fmt.Printf("Comando desconocido: %s\n", os.Args[1])
			os.Exit(1)
		}
	}

	go startHTTPServer(lib, live)
	startLobbyServer(lib, hub)
}
GOEOF

cat > "${SRC_DIR}/control.sh" <<'EOF'
#!/usr/bin/env bash
# Wrapper de administración: corre comandos contra el binario, vía el control socket no aplica
# (este servidor usa CLI directo sobre el mismo binario, no socket de control separado).
BIN="/opt/streamserver/streamserver"
"$BIN" "$@"
EOF
chmod +x "${SRC_DIR}/control.sh"

# ------------------------------------------------------------------
# 6. Resolver dependencias Go, compilar, instalar systemd, arrancar
# ------------------------------------------------------------------
echo
echo "[6/6] Compilando y dejando el servicio corriendo..."
cd "${SRC_DIR}"
export PATH="/usr/local/go/bin:${PATH}"
export GOFLAGS="-mod=mod"
go mod edit -require=github.com/google/uuid@v1.6.0
go mod tidy -e
go build -o "${INSTALL_DIR}/streamserver" .
chmod +x "${INSTALL_DIR}/streamserver"

# Token de administración simple, por si en el futuro se protege un endpoint HTTP de admin.
if [ ! -f "${ADMIN_TOKEN_FILE}" ]; then
  head -c 24 /dev/urandom | base64 | tr -d '/+=' > "${ADMIN_TOKEN_FILE}"
fi

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Stream Server (Go) - proxy + lobby
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/streamserver serve
Restart=always
RestartSec=3
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" >/dev/null
systemctl restart "${SERVICE_NAME}"

# Symlink para usar el CLI de administración cómodamente
ln -sf "${INSTALL_DIR}/streamserver" /usr/local/bin/streamserver

sleep 2
ACTIVE="$(systemctl is-active ${SERVICE_NAME} || true)"

echo
echo "=================================================="
if [ "$ACTIVE" = "active" ]; then
  echo "  Instalación completa. Servicio corriendo."
else
  echo "  AVISO: el servicio no parece estar activo."
  echo "  Revisa con: journalctl -u ${SERVICE_NAME} -n 50"
fi
echo "=================================================="
echo
echo "Puertos:"
echo "  HTTP streaming (contenido):  ${HTTP_PORT}"
echo "  Lobby (cliente Android):     ${LOBBY_PORT}"
echo
echo "Comandos de administración (desde cualquier carpeta):"
echo "  streamserver add-manual \"Nombre\" \"https://url-directa.m3u8\" [duracion_segundos]"
echo "  streamserver add-library \"Nombre\" \"https://pagina-origen\""
echo "  streamserver add-live \"Nombre\" \"https://canal-en-vivo\""
echo "  streamserver list"
echo
echo "El servicio queda corriendo solo (systemd) y se reinicia automaticamente"
echo "si el VPS reinicia. Logs: journalctl -u ${SERVICE_NAME} -f"
echo
