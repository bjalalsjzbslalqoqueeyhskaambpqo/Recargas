#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" -ne 0 ] && { echo "ERROR: necesita root"; exit 1; }

GO_VERSION="1.22.5"
INSTALL_DIR="/opt/streamserver"
SRC_DIR="${INSTALL_DIR}/src"
CACHE_ROOT="/root/dvr_cache"
DATA_FILE="${INSTALL_DIR}/library.json"
SERVICE_NAME="streamserver"
HTTP_PORT="8383"
LOBBY_PORT="8384"
ADMIN_PORT="8385"

echo "=================================================="
echo "  Instalando Stream Server (Go) + dependencias"
echo "=================================================="

echo "[1/6] Paquetes del sistema..."
apt-get update -qq
apt-get install -y -qq curl wget tar python3 python3-pip ffmpeg jq >/dev/null

echo "[2/6] Instalando/actualizando yt-dlp..."
PIP_HELP="$(python3 -m pip install --help || true)"
if echo "$PIP_HELP" | grep -q -- "--break-system-packages"; then
  python3 -m pip install --upgrade yt-dlp --break-system-packages -q
else
  python3 -m pip install --upgrade yt-dlp -q
fi
echo "      yt-dlp: $(yt-dlp --version 2>/dev/null || echo instalado)"

echo "[3/6] Instalando Go ${GO_VERSION}..."
if command -v go >/dev/null 2>&1 && go version | grep -q "${GO_VERSION}"; then
  echo "      Go ${GO_VERSION} ya esta instalado."
else
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) GOARCH="amd64" ;;
    aarch64) GOARCH="arm64" ;;
    *) echo "ERROR: arquitectura no soportada: $ARCH"; exit 1 ;;
  esac
  cd /tmp
  wget -q "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" -O go.tar.gz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf go.tar.gz
  rm -f go.tar.gz
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
fi
export PATH="/usr/local/go/bin:${PATH}"
echo "      $(go version)"

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
fi

echo "[5/6] Generando codigo fuente..."
systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
mkdir -p "${SRC_DIR}" "${CACHE_ROOT}"

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
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/google/uuid"
)

const (
	httpPort  = "8383"
	lobbyPort = "8384"
	adminPort = "8385"
	cacheRoot = "/root/dvr_cache"
	dataFile  = "/opt/streamserver/library.json"
	resolveTimeoutSec = 30
)

var qualities = map[string]string{
	"480": "best[height<=480]",
	"720": "best[height<=720]",
}

type ContentItem struct {
	ID              string            `json:"id"`
	Name            string            `json:"name,omitempty"`
	URL             string            `json:"url,omitempty"`
	Thumbnail       *string           `json:"thumbnail,omitempty"`
	DurationSeconds *int              `json:"duration_seconds,omitempty"`
	IsLive          bool              `json:"is_live,omitempty"`
	Status          string            `json:"status"`
	Mode            string            `json:"mode"`
	SourceURL       string            `json:"source_url,omitempty"`
	QualityURLs     map[string]string `json:"quality_urls,omitempty"`
	QualityReady    map[string]bool   `json:"quality_ready,omitempty"`
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

func (l *Library) Delete(id string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	_, ok := l.items[id]
	if ok {
		delete(l.items, id)
	}
	return ok
}

func (l *Library) ListForClient() []ContentItem {
	l.mu.RLock()
	defer l.mu.RUnlock()
	out := make([]ContentItem, 0, len(l.items))
	for _, it := range l.items {
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

func (l *Library) ListAll() []ContentItem {
	l.mu.RLock()
	defer l.mu.RUnlock()
	out := make([]ContentItem, 0, len(l.items))
	for _, it := range l.items {
		cp := *it
		out = append(out, cp)
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

type LobbyClient struct {
	deviceID string
	writer   *bufio.Writer
	mu       sync.Mutex
}

type LobbyHub struct {
	mu      sync.Mutex
	clients map[string]*LobbyClient
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
			log.Printf("[lobby] error escribiendo a %s: %v", id, err)
			delete(h.clients, id)
		}
	}
}

func resolveQualityURL(pageURL, format string) (string, error) {
	cmd := exec.Command("yt-dlp", "-g", "--no-playlist", "--quiet", "-f", format, pageURL)
	var out, errOut bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errOut
	done := make(chan error, 1)
	if err := cmd.Start(); err != nil {
		return "", err
	}
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			return "", fmt.Errorf("yt-dlp: %v (%s)", err, strings.TrimSpace(errOut.String()))
		}
	case <-time.After(resolveTimeoutSec * time.Second):
		cmd.Process.Kill()
		return "", fmt.Errorf("yt-dlp timeout resolviendo %s", format)
	}
	line := strings.TrimSpace(out.String())
	if line == "" {
		return "", fmt.Errorf("yt-dlp no devolvio URL")
	}
	return strings.Split(line, "\n")[0], nil
}

type ytDlpMeta struct {
	Duration  float64 `json:"duration"`
	Thumbnail string  `json:"thumbnail"`
}

func resolveMetadata(pageURL string) (*ytDlpMeta, error) {
	cmd := exec.Command("yt-dlp", "--no-playlist", "--quiet", "--dump-json", pageURL)
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Run(); err != nil {
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
	client := &http.Client{Timeout: 0}
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

func processLibraryItem(lib *Library, hub *LobbyHub, item *ContentItem) {
	log.Printf("[library][%s] iniciando procesamiento de: %s", item.ID, item.SourceURL)
	itemDir := filepath.Join(cacheRoot, item.ID)
	if err := os.MkdirAll(itemDir, 0o755); err != nil {
		log.Printf("[library][%s] mkdir error: %v", item.ID, err)
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
		log.Printf("[library][%s] metadata error: %v", item.ID, err)
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
				log.Printf("[library][%s] resolve %s error: %v", item.ID, quality, err)
				return
			}
			dest := filepath.Join(itemDir, quality+".mp4")
			log.Printf("[library][%s] descargando calidad %s...", item.ID, quality)
			if err := downloadToFile(resolved, dest); err != nil {
				log.Printf("[library][%s] download %s error: %v", item.ID, quality, err)
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
		if _, ok := item.QualityURLs["720"]; ok {
			item.URL = "/content/" + item.ID + "/720"
		} else {
			item.URL = "/content/" + item.ID + "/480"
		}
		item.Status = "ready"
		log.Printf("[library][%s] procesamiento completo, status=ready", item.ID)
	} else {
		item.Status = "failed"
		log.Printf("[library][%s] procesamiento fallido, todas las calidades fallaron", item.ID)
	}
	lib.Save()
	hub.BroadcastContentList(lib)
}

type LiveSession struct {
	mu      sync.Mutex
	cmd     *exec.Cmd
	stdout  io.ReadCloser
	clients map[chan []byte]bool
	started bool
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
			sess.cmd.Process.Kill()
			log.Printf("[live][%s] sin viewers, proceso yt-dlp detenido", contentID)
		}
	}
}

func startHTTPServer(lib *Library, live *LiveManager) {
	mux := http.NewServeMux()
	mux.HandleFunc("/content/", func(w http.ResponseWriter, r *http.Request) {
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
			http.Error(w, "no se pudo iniciar stream en vivo", http.StatusBadGateway)
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

func startAdminServer(lib *Library, hub *LobbyHub) {
	mux := http.NewServeMux()

	mux.HandleFunc("/admin/add-manual", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST requerido", http.StatusMethodNotAllowed)
			return
		}
		var req struct {
			Name     string `json:"name"`
			URL      string `json:"url"`
			Duration int    `json:"duration"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Name == "" || req.URL == "" {
			http.Error(w, "name y url requeridos", http.StatusBadRequest)
			return
		}
		id := uuid.NewString()
		item := &ContentItem{
			ID:     id,
			Name:   req.Name,
			URL:    req.URL,
			Status: "ready",
			Mode:   "manual",
		}
		if req.Duration > 0 {
			item.DurationSeconds = &req.Duration
		}
		lib.Add(item)
		lib.Save()
		hub.BroadcastContentList(lib)
		log.Printf("[admin] add-manual: %s (%s)", req.Name, id)
		json.NewEncoder(w).Encode(map[string]string{"id": id, "status": "ready"})
	})

	mux.HandleFunc("/admin/add-library", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST requerido", http.StatusMethodNotAllowed)
			return
		}
		var req struct {
			Name      string `json:"name"`
			SourceURL string `json:"source_url"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Name == "" || req.SourceURL == "" {
			http.Error(w, "name y source_url requeridos", http.StatusBadRequest)
			return
		}
		id := uuid.NewString()
		item := &ContentItem{
			ID:           id,
			Name:         req.Name,
			SourceURL:    req.SourceURL,
			Status:       "processing",
			Mode:         "library",
			QualityURLs:  make(map[string]string),
			QualityReady: make(map[string]bool),
		}
		lib.Add(item)
		lib.Save()
		hub.BroadcastContentList(lib)
		log.Printf("[admin] add-library: %s (%s) <- %s", req.Name, id, req.SourceURL)
		go processLibraryItem(lib, hub, item)
		json.NewEncoder(w).Encode(map[string]string{"id": id, "status": "processing"})
	})

	mux.HandleFunc("/admin/add-live", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST requerido", http.StatusMethodNotAllowed)
			return
		}
		var req struct {
			Name      string `json:"name"`
			SourceURL string `json:"source_url"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Name == "" || req.SourceURL == "" {
			http.Error(w, "name y source_url requeridos", http.StatusBadRequest)
			return
		}
		id := uuid.NewString()
		item := &ContentItem{
			ID:        id,
			Name:      req.Name,
			SourceURL: req.SourceURL,
			URL:       "/live/" + id,
			Status:    "ready",
			Mode:      "live",
			IsLive:    true,
		}
		lib.Add(item)
		lib.Save()
		hub.BroadcastContentList(lib)
		log.Printf("[admin] add-live: %s (%s)", req.Name, id)
		json.NewEncoder(w).Encode(map[string]string{"id": id, "status": "ready"})
	})

	mux.HandleFunc("/admin/delete", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST requerido", http.StatusMethodNotAllowed)
			return
		}
		var req struct {
			ID string `json:"id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ID == "" {
			http.Error(w, "id requerido", http.StatusBadRequest)
			return
		}
		if lib.Delete(req.ID) {
			lib.Save()
			hub.BroadcastContentList(lib)
			log.Printf("[admin] delete: %s", req.ID)
			json.NewEncoder(w).Encode(map[string]string{"status": "deleted"})
		} else {
			http.Error(w, "id no encontrado", http.StatusNotFound)
		}
	})

	mux.HandleFunc("/admin/list", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(lib.ListAll())
	})

	mux.HandleFunc("/admin/retry", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST requerido", http.StatusMethodNotAllowed)
			return
		}
		var req struct {
			ID string `json:"id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ID == "" {
			http.Error(w, "id requerido", http.StatusBadRequest)
			return
		}
		item, ok := lib.Get(req.ID)
		if !ok {
			http.Error(w, "id no encontrado", http.StatusNotFound)
			return
		}
		if item.Mode != "library" {
			http.Error(w, "solo items de tipo library pueden reintentarse", http.StatusBadRequest)
			return
		}
		item.Status = "processing"
		item.QualityURLs = make(map[string]string)
		item.QualityReady = make(map[string]bool)
		lib.Save()
		hub.BroadcastContentList(lib)
		log.Printf("[admin] retry: %s (%s)", item.Name, item.ID)
		go processLibraryItem(lib, hub, item)
		json.NewEncoder(w).Encode(map[string]string{"status": "processing"})
	})

	srv := &http.Server{Addr: "127.0.0.1:" + adminPort, Handler: mux}
	log.Printf("[admin] escuchando en 127.0.0.1:%s", adminPort)
	log.Fatal(srv.ListenAndServe())
}

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
	resp := "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n"
	if _, err := conn.Write([]byte(resp)); err != nil {
		return
	}
	writer := bufio.NewWriter(conn)
	client := &LobbyClient{deviceID: deviceID, writer: writer}
	hub.Register(client)
	defer hub.Unregister(deviceID)
	log.Printf("[lobby] dispositivo conectado: %s", deviceID)
	sendLine(client, map[string]interface{}{"type": "state", "status": "ready"})
	sendLine(client, map[string]interface{}{"type": "content_list", "items": lib.ListForClient()})
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

func resumeProcessing(lib *Library, hub *LobbyHub) {
	items := lib.ListAll()
	for _, it := range items {
		if it.Mode == "library" && it.Status == "processing" {
			log.Printf("[startup] retomando procesamiento de: %s (%s)", it.Name, it.ID)
			item, _ := lib.Get(it.ID)
			go processLibraryItem(lib, hub, item)
		}
	}
}

func adminCLI(args []string) {
	base := "http://127.0.0.1:" + adminPort
	client := &http.Client{Timeout: 10 * time.Second}

	doPost := func(path string, body interface{}) {
		data, _ := json.Marshal(body)
		resp, err := client.Post(base+path, "application/json", bytes.NewReader(data))
		if err != nil {
			fmt.Printf("ERROR: no se pudo conectar al servidor: %v\n", err)
			fmt.Println("El servidor esta corriendo? systemctl status streamserver")
			os.Exit(1)
		}
		defer resp.Body.Close()
		io.Copy(os.Stdout, resp.Body)
		fmt.Println()
	}

	switch args[0] {
	case "add-manual":
		if len(args) < 3 {
			fmt.Println("Uso: streamserver add-manual <nombre> <url> [duracion_segundos]")
			os.Exit(1)
		}
		dur := 0
		if len(args) > 3 {
			dur, _ = strconv.Atoi(args[3])
		}
		doPost("/admin/add-manual", map[string]interface{}{"name": args[1], "url": args[2], "duration": dur})

	case "add-library":
		if len(args) < 3 {
			fmt.Println("Uso: streamserver add-library <nombre> <url-origen>")
			os.Exit(1)
		}
		doPost("/admin/add-library", map[string]interface{}{"name": args[1], "source_url": args[2]})

	case "add-live":
		if len(args) < 3 {
			fmt.Println("Uso: streamserver add-live <nombre> <url-origen>")
			os.Exit(1)
		}
		doPost("/admin/add-live", map[string]interface{}{"name": args[1], "source_url": args[2]})

	case "delete":
		if len(args) < 2 {
			fmt.Println("Uso: streamserver delete <id>")
			os.Exit(1)
		}
		doPost("/admin/delete", map[string]interface{}{"id": args[1]})

	case "retry":
		if len(args) < 2 {
			fmt.Println("Uso: streamserver retry <id>")
			os.Exit(1)
		}
		doPost("/admin/retry", map[string]interface{}{"id": args[1]})

	case "list":
		resp, err := client.Get(base + "/admin/list")
		if err != nil {
			fmt.Printf("ERROR: %v\n", err)
			os.Exit(1)
		}
		defer resp.Body.Close()
		var items []ContentItem
		json.NewDecoder(resp.Body).Decode(&items)
		for _, it := range items {
			live := ""
			if it.IsLive {
				live = " [EN VIVO]"
			}
			fmt.Printf("- %s | %s | %s | %s%s\n", it.ID, it.Name, it.Mode, it.Status, live)
		}

	default:
		fmt.Printf("Comando desconocido: %s\n", args[0])
		os.Exit(1)
	}
}

func main() {
	if len(os.Args) > 1 && os.Args[1] != "serve" {
		adminCLI(os.Args[1:])
		return
	}

	lib := NewLibrary()
	if err := lib.Load(); err != nil {
		log.Printf("[main] aviso: no se pudo cargar biblioteca: %v", err)
	}
	hub := NewLobbyHub()
	live := NewLiveManager()

	resumeProcessing(lib, hub)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-sig
		log.Println("[main] senal recibida, guardando y saliendo...")
		lib.Save()
		os.Exit(0)
	}()

	go startAdminServer(lib, hub)
	go startHTTPServer(lib, live)
	startLobbyServer(lib, hub)
}
GOEOF

systemctl stop streamserver 2>/dev/null || true
sleep 2
fuser -k 8383/tcp 2>/dev/null || true
fuser -k 8384/tcp 2>/dev/null || true
fuser -k 8385/tcp 2>/dev/null || true
sleep 1

echo "[6/6] Compilando y desplegando..."
cd "${SRC_DIR}"
export PATH="/usr/local/go/bin:${PATH}"
export GOFLAGS="-mod=mod"
go mod edit -require=github.com/google/uuid@v1.6.0
go mod tidy -e
go build -o "${INSTALL_DIR}/streamserver" .
chmod +x "${INSTALL_DIR}/streamserver"

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
ln -sf "${INSTALL_DIR}/streamserver" /usr/local/bin/streamserver

sleep 2
ACTIVE="$(systemctl is-active ${SERVICE_NAME} || true)"
echo
echo "=================================================="
if [ "$ACTIVE" = "active" ]; then
  echo "  Instalacion completa. Servicio corriendo."
else
  echo "  AVISO: el servicio no parece estar activo."
  echo "  Revisa con: journalctl -u ${SERVICE_NAME} -n 50"
fi
echo "=================================================="
echo
echo "Puertos:"
echo "  HTTP streaming:  ${HTTP_PORT}"
echo "  Lobby Android:   ${LOBBY_PORT}"
echo "  Admin interno:   ${ADMIN_PORT} (solo localhost)"
echo
echo "Comandos:"
echo "  streamserver add-manual <nombre> <url> [segundos]"
echo "  streamserver add-library <nombre> <url-origen>"
echo "  streamserver add-live <nombre> <url-origen>"
echo "  streamserver retry <id>"
echo "  streamserver delete <id>"
echo "  streamserver list"
echo "  journalctl -u streamserver -f"
