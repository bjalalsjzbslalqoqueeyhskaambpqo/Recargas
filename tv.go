#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" -ne 0 ] && { echo "ERROR: necesita root"; exit 1; }

GO_VERSION="1.22.5"
INSTALL_DIR="/opt/streamserver"
SRC_DIR="${INSTALL_DIR}/src"
CACHE_ROOT="/root/dvr_cache"
SERVICE_NAME="streamserver"
HTTP_PORT="8383"
LOBBY_PORT="8384"
ADMIN_PORT="8385"

echo "=================================================="
echo "  Stream Server - Instalador / Actualizador"
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

echo "[5/6] Deteniendo servicios anteriores y generando codigo..."
systemctl stop streamserver 2>/dev/null || true
systemctl stop streamproxy 2>/dev/null || true
systemctl disable streamproxy 2>/dev/null || true
sleep 1
fuser -k ${HTTP_PORT}/tcp 2>/dev/null || true
fuser -k ${LOBBY_PORT}/tcp 2>/dev/null || true
fuser -k ${ADMIN_PORT}/tcp 2>/dev/null || true
sleep 1

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
	httpPort          = "8383"
	lobbyPort         = "8384"
	adminPort         = "8385"
	cacheRoot         = "/root/dvr_cache"
	dataFile          = "/opt/streamserver/library.json"
	resolveTimeoutSec = 30
	liveSegmentBuffer = 10
	segmentPollSec    = 2
	minSegmentsReady  = 3
)

var qualities = []string{"720", "480"}

var qualityFormats = map[string]string{
	"720": "best[height<=720]",
	"480": "best[height<=480]",
}

var qualityBandwidth = map[string]int{
	"720": 2800000,
	"480": 1200000,
}

var qualityResolution = map[string]string{
	"720": "1280x720",
	"480": "854x480",
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
	QualityDirs     map[string]string `json:"quality_dirs,omitempty"`
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
		if it.QualityDirs == nil {
			it.QualityDirs = make(map[string]string)
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

func resolveDirectURL(sourceURL, format string) (string, error) {
	cmd := exec.Command("yt-dlp", "-g", "--no-playlist", "--quiet", "-f", format, sourceURL)
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
		return "", fmt.Errorf("yt-dlp timeout")
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

func resolveMetadata(sourceURL string) (*ytDlpMeta, error) {
	cmd := exec.Command("yt-dlp", "--no-playlist", "--quiet", "--dump-json", sourceURL)
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

func fetchBytes(url string) ([]byte, error) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
	req.Header.Set("Referer", "https://rumble.com/")
	client := &http.Client{Timeout: 20 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

func parseM3U8Segments(content, baseURL string) (int, []struct{ url string; dur float64 }) {
	lines := strings.Split(content, "\n")
	targetDuration := 6
	var segs []struct{ url string; dur float64 }
	var pendingDur float64
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "#EXT-X-TARGETDURATION:") {
			v, err := strconv.Atoi(strings.TrimPrefix(line, "#EXT-X-TARGETDURATION:"))
			if err == nil {
				targetDuration = v
			}
		} else if strings.HasPrefix(line, "#EXTINF:") {
			val := strings.TrimPrefix(line, "#EXTINF:")
			val = strings.Split(val, ",")[0]
			f, err := strconv.ParseFloat(val, 64)
			if err == nil {
				pendingDur = f
			} else {
				pendingDur = 6.0
			}
		} else if line != "" && !strings.HasPrefix(line, "#") {
			segURL := line
			if !strings.HasPrefix(line, "http") {
				base := baseURL
				if idx := strings.LastIndex(base, "/"); idx >= 0 {
					base = base[:idx]
				}
				segURL = base + "/" + line
			}
			dur := pendingDur
			if dur == 0 {
				dur = 6.0
			}
			segs = append(segs, struct{ url string; dur float64 }{segURL, dur})
			pendingDur = 0
		}
	}
	return targetDuration, segs
}

func processLibraryItem(lib *Library, hub *LobbyHub, item *ContentItem) {
	log.Printf("[library][%s] iniciando: %s", item.ID, item.SourceURL)

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
	}

	itemDir := filepath.Join(cacheRoot, item.ID)
	if err := os.MkdirAll(itemDir, 0o755); err != nil {
		log.Printf("[library][%s] mkdir error: %v", item.ID, err)
		item.Status = "failed"
		lib.Save()
		hub.BroadcastContentList(lib)
		return
	}

	var wg sync.WaitGroup
	var mu sync.Mutex
	anyReady := false

	for _, quality := range qualities {
		format := qualityFormats[quality]
		wg.Add(1)
		go func(quality, format string) {
			defer wg.Done()
			log.Printf("[library][%s] resolviendo calidad %s...", item.ID, quality)
			m3u8URL, err := resolveDirectURL(item.SourceURL, format)
			if err != nil {
				log.Printf("[library][%s] resolve %s error: %v", item.ID, quality, err)
				return
			}

			qDir := filepath.Join(itemDir, quality)
			if err := os.MkdirAll(qDir, 0o755); err != nil {
				log.Printf("[library][%s] mkdir %s error: %v", item.ID, quality, err)
				return
			}

			log.Printf("[library][%s] descargando segmentos %s...", item.ID, quality)
			seen := map[string]bool{}
			idx := 0
			var allSegs []struct{ fname string; dur float64 }
			targetDur := 6

			for {
				data, err := fetchBytes(m3u8URL)
				if err != nil {
					log.Printf("[library][%s] fetch m3u8 %s error: %v", item.ID, quality, err)
					break
				}
				content := string(data)
				td, segs := parseM3U8Segments(content, m3u8URL)
				targetDur = td

				newSegs := 0
				for _, seg := range segs {
					if seen[seg.url] {
						continue
					}
					seen[seg.url] = true
					segData, err := fetchBytes(seg.url)
					if err != nil {
						log.Printf("[library][%s] fetch seg %s error: %v", item.ID, quality, err)
						continue
					}
					fname := fmt.Sprintf("seg_%08d.ts", idx)
					fpath := filepath.Join(qDir, fname)
					if err := os.WriteFile(fpath, segData, 0o644); err != nil {
						log.Printf("[library][%s] write seg error: %v", item.ID, err)
						continue
					}
					allSegs = append(allSegs, struct{ fname string; dur float64 }{fname, seg.dur})
					idx++
					newSegs++
				}

				if strings.Contains(content, "#EXT-X-ENDLIST") {
					log.Printf("[library][%s] calidad %s completa (%d segmentos)", item.ID, quality, idx)
					break
				}
				if newSegs == 0 && len(segs) > 0 {
					log.Printf("[library][%s] calidad %s sin segmentos nuevos, fin", item.ID, quality)
					break
				}
				time.Sleep(segmentPollSec * time.Second)
			}

			if len(allSegs) == 0 {
				log.Printf("[library][%s] calidad %s sin segmentos descargados", item.ID, quality)
				return
			}

			playlistLines := []string{
				"#EXTM3U",
				"#EXT-X-VERSION:3",
				fmt.Sprintf("#EXT-X-TARGETDURATION:%d", targetDur),
				"#EXT-X-MEDIA-SEQUENCE:0",
				"#EXT-X-PLAYLIST-TYPE:VOD",
			}
			for _, s := range allSegs {
				playlistLines = append(playlistLines,
					fmt.Sprintf("#EXTINF:%.3f,", s.dur),
					s.fname+".ts" ,
				)
			}

			playlistLines = append(playlistLines, "#EXT-X-ENDLIST")
			playlistContent := strings.Join(playlistLines, "\n") + "\n"
			playlistPath := filepath.Join(qDir, "playlist.m3u8")
			if err := os.WriteFile(playlistPath, []byte(playlistContent), 0o644); err != nil {
				log.Printf("[library][%s] write playlist error: %v", item.ID, err)
				return
			}

			mu.Lock()
			item.QualityDirs[quality] = qDir
			item.QualityReady[quality] = true
			anyReady = true
			mu.Unlock()
			log.Printf("[library][%s] calidad %s lista", item.ID, quality)
		}(quality, format)
	}

	wg.Wait()

	if anyReady {
		item.URL = "/hls/" + item.ID + "/master.m3u8"
		item.Status = "ready"
		log.Printf("[library][%s] procesamiento completo", item.ID)
	} else {
		item.Status = "failed"
		log.Printf("[library][%s] procesamiento fallido", item.ID)
	}
	lib.Save()
	hub.BroadcastContentList(lib)
}

type LiveSegment struct {
	fname string
	dur   float64
}

type LiveStream struct {
	mu            sync.RWMutex
	segments      []LiveSegment
	targetDur     int
	mediaSequence int
	ready         bool
	stop          chan struct{}
}

type LiveManager struct {
	mu      sync.Mutex
	streams map[string]*LiveStream
}

func NewLiveManager() *LiveManager {
	return &LiveManager{streams: make(map[string]*LiveStream)}
}

func (m *LiveManager) GetOrCreate(id, sourceURL string) *LiveStream {
	m.mu.Lock()
	defer m.mu.Unlock()
	if ls, ok := m.streams[id]; ok {
		return ls
	}
	ls := &LiveStream{
		targetDur: 6,
		stop:      make(chan struct{}),
	}
	m.streams[id] = ls
	go m.runLive(id, sourceURL, ls)
	return ls
}

func (m *LiveManager) Stop(id string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if ls, ok := m.streams[id]; ok {
		close(ls.stop)
		delete(m.streams, id)
	}
}

func (m *LiveManager) runLive(id, sourceURL string, ls *LiveStream) {
	liveDir := filepath.Join(cacheRoot, "live_"+id)
	os.MkdirAll(liveDir, 0o755)

	log.Printf("[live][%s] resolviendo URL...", id)
	m3u8URL, err := resolveDirectURL(sourceURL, "best[height<=720]/best")
	if err != nil {
		log.Printf("[live][%s] resolve error: %v", id, err)
		return
	}
	log.Printf("[live][%s] URL resuelta, grabando segmentos...", id)

	seen := map[string]bool{}
	idx := 0

	for {
		select {
		case <-ls.stop:
			log.Printf("[live][%s] detenido", id)
			os.RemoveAll(liveDir)
			return
		default:
		}

		data, err := fetchBytes(m3u8URL)
		if err != nil {
			log.Printf("[live][%s] fetch m3u8 error: %v", id, err)
			time.Sleep(segmentPollSec * time.Second)
			continue
		}
		content := string(data)
		td, segs := parseM3U8Segments(content, m3u8URL)

		ls.mu.Lock()
		ls.targetDur = td
		ls.mu.Unlock()

		for _, seg := range segs {
			if seen[seg.url] {
				continue
			}
			seen[seg.url] = true

			segData, err := fetchBytes(seg.url)
			if err != nil {
				log.Printf("[live][%s] fetch seg error: %v", id, err)
				continue
			}

			fname := fmt.Sprintf("seg_%08d.ts", idx)
			fpath := filepath.Join(liveDir, fname)
			if err := os.WriteFile(fpath, segData, 0o644); err != nil {
				log.Printf("[live][%s] write seg error: %v", id, err)
				continue
			}

			ls.mu.Lock()
			ls.segments = append(ls.segments, LiveSegment{fname: fname, dur: seg.dur})
			if len(ls.segments) > liveSegmentBuffer {
				old := ls.segments[0]
				ls.segments = ls.segments[1:]
				ls.mediaSequence++
				os.Remove(filepath.Join(liveDir, old.fname))
			}
			if !ls.ready && len(ls.segments) >= minSegmentsReady {
				ls.ready = true
				log.Printf("[live][%s] listo para servir", id)
			}
			ls.mu.Unlock()
			idx++
		}

		time.Sleep(segmentPollSec * time.Second)
	}
}

func startHTTPServer(lib *Library, lm *LiveManager) {
	mux := http.NewServeMux()

	mux.HandleFunc("/hls/", func(w http.ResponseWriter, r *http.Request) {
		parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/hls/"), "/")
		if len(parts) < 2 {
			http.NotFound(w, r)
			return
		}
		id := parts[0]
		rest := strings.Join(parts[1:], "/")

		item, ok := lib.Get(id)
		if !ok {
			http.NotFound(w, r)
			return
		}

		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Cache-Control", "no-cache")

		if item.IsLive {
			ls := lm.GetOrCreate(id, item.SourceURL)
			if rest == "master.m3u8" {
				ls.mu.RLock()
				ready := ls.ready
				ls.mu.RUnlock()
				if !ready {
					http.Error(w, "stream no listo aun", http.StatusServiceUnavailable)
					return
				}
				body := "#EXTM3U\n#EXT-X-VERSION:3\n"
				body += fmt.Sprintf("#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720\n")
				body += fmt.Sprintf("/hls/%s/live.m3u8\n", id)
				w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
				w.Write([]byte(body))
				return
			}
			if rest == "live.m3u8" {
				ls.mu.RLock()
				segs := make([]LiveSegment, len(ls.segments))
				copy(segs, ls.segments)
				seq := ls.mediaSequence
				td := ls.targetDur
				ready := ls.ready
				ls.mu.RUnlock()
				if !ready {
					http.Error(w, "stream no listo aun", http.StatusServiceUnavailable)
					return
				}
				lines := []string{
					"#EXTM3U",
					"#EXT-X-VERSION:3",
					fmt.Sprintf("#EXT-X-TARGETDURATION:%d", td),
					fmt.Sprintf("#EXT-X-MEDIA-SEQUENCE:%d", seq),
				}
				for _, s := range segs {
					lines = append(lines,
						fmt.Sprintf("#EXTINF:%.3f,", s.dur),
						fmt.Sprintf("/hls/%s/seg/%s", id, s.fname),
					)
				}
				body := strings.Join(lines, "\n") + "\n"
				w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
				w.Write([]byte(body))
				return
			}
			if strings.HasPrefix(rest, "seg/") {
				fname := strings.TrimPrefix(rest, "seg/")
				if strings.Contains(fname, "..") || strings.Contains(fname, "/") {
					http.NotFound(w, r)
					return
				}
				fpath := filepath.Join(cacheRoot, "live_"+id, fname)
				data, err := os.ReadFile(fpath)
				if err != nil {
					http.NotFound(w, r)
					return
				}
				w.Header().Set("Content-Type", "video/MP2T")
				w.Header().Set("Content-Length", strconv.Itoa(len(data)))
				w.Write(data)
				return
			}
			http.NotFound(w, r)
			return
		}

		if rest == "master.m3u8" {
			lines := []string{"#EXTM3U", "#EXT-X-VERSION:3"}
			for _, q := range qualities {
				if !item.QualityReady[q] {
					continue
				}
				lines = append(lines,
					fmt.Sprintf("#EXT-X-STREAM-INF:BANDWIDTH=%d,RESOLUTION=%s", qualityBandwidth[q], qualityResolution[q]),
					fmt.Sprintf("/hls/%s/%s/playlist.m3u8", id, q),
				)
			}
			body := strings.Join(lines, "\n") + "\n"
			w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			w.Write([]byte(body))
			return
		}

		if len(parts) >= 3 {
			quality := parts[1]
			fname := parts[2]
			if strings.Contains(fname, "..") {
				http.NotFound(w, r)
				return
			}
			qDir, ok := item.QualityDirs[quality]
			if !ok {
				http.NotFound(w, r)
				return
			}
			fpath := filepath.Join(qDir, fname)
			if strings.HasSuffix(fname, ".m3u8") {
				data, err := os.ReadFile(fpath)
				if err != nil {
					http.NotFound(w, r)
					return
				}
				w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
				w.Write(data)
				return
			}
			if strings.HasSuffix(fname, ".ts") {
				data, err := os.ReadFile(fpath)
				if err != nil {
					http.NotFound(w, r)
					return
				}
				w.Header().Set("Content-Type", "video/MP2T")
				w.Header().Set("Content-Length", strconv.Itoa(len(data)))
				w.Write(data)
				return
			}
		}
		http.NotFound(w, r)
	})

	mux.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(lib.ListForClient())
	})

	srv := &http.Server{Addr: ":" + httpPort, Handler: mux}
	log.Printf("[http] sirviendo en :%s", httpPort)
	log.Fatal(srv.ListenAndServe())
}

func startAdminServer(lib *Library, hub *LobbyHub, lm *LiveManager) {
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
			ID:          id,
			Name:        req.Name,
			SourceURL:   req.SourceURL,
			Status:      "processing",
			Mode:        "library",
			QualityDirs: make(map[string]string),
			QualityReady: make(map[string]bool),
		}
		lib.Add(item)
		lib.Save()
		hub.BroadcastContentList(lib)
		log.Printf("[admin] add-library: %s (%s)", req.Name, id)
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
			URL:       "/hls/" + id + "/master.m3u8",
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
		item, ok := lib.Get(req.ID)
		if !ok {
			http.Error(w, "id no encontrado", http.StatusNotFound)
			return
		}
		if item.IsLive {
			lm.Stop(req.ID)
		}
		lib.Delete(req.ID)
		os.RemoveAll(filepath.Join(cacheRoot, req.ID))
		lib.Save()
		hub.BroadcastContentList(lib)
		log.Printf("[admin] delete: %s", req.ID)
		json.NewEncoder(w).Encode(map[string]string{"status": "deleted"})
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
			http.Error(w, "solo items library pueden reintentarse", http.StatusBadRequest)
			return
		}
		item.Status = "processing"
		item.QualityDirs = make(map[string]string)
		item.QualityReady = make(map[string]bool)
		os.RemoveAll(filepath.Join(cacheRoot, item.ID))
		lib.Save()
		hub.BroadcastContentList(lib)
		log.Printf("[admin] retry: %s (%s)", item.Name, item.ID)
		go processLibraryItem(lib, hub, item)
		json.NewEncoder(w).Encode(map[string]string{"status": "processing"})
	})

	mux.HandleFunc("/admin/list", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(lib.ListAll())
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
	log.Printf("[lobby] escuchando en :%s", lobbyPort)
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
	conn.Write([]byte("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n"))
	writer := bufio.NewWriter(conn)
	client := &LobbyClient{deviceID: deviceID, writer: writer}
	hub.Register(client)
	defer hub.Unregister(deviceID)
	log.Printf("[lobby] conectado: %s", deviceID)
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
		switch msg["type"] {
		case "hello":
		case "play":
			log.Printf("[lobby] %s play: %v", deviceID, msg["content_id"])
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
	for _, it := range lib.ListAll() {
		if it.Mode == "library" && it.Status == "processing" {
			log.Printf("[startup] retomando: %s (%s)", it.Name, it.ID)
			item, _ := lib.Get(it.ID)
			item.QualityDirs = make(map[string]string)
			item.QualityReady = make(map[string]bool)
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
			fmt.Printf("ERROR: servidor no disponible: %v\n", err)
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
		log.Printf("[main] error cargando biblioteca: %v", err)
	}
	hub := NewLobbyHub()
	lm := NewLiveManager()

	resumeProcessing(lib, hub)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-sig
		log.Println("[main] guardando y saliendo...")
		lib.Save()
		os.Exit(0)
	}()

	go startAdminServer(lib, hub, lm)
	go startHTTPServer(lib, lm)
	startLobbyServer(lib, hub)
}
GOEOF

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
Description=Stream Server (Go) - HLS proxy + lobby
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
  echo "  AVISO: servicio no activo."
  echo "  Revisa: journalctl -u ${SERVICE_NAME} -n 50"
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
