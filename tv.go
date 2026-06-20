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
echo "  Stream Server - Actualizador V7 (Thumbnails)"
echo "=================================================="

echo "[1/4] Deteniendo servicios..."
systemctl stop streamserver 2>/dev/null || true
fuser -k ${HTTP_PORT}/tcp 2>/dev/null || true
fuser -k ${LOBBY_PORT}/tcp 2>/dev/null || true
fuser -k ${ADMIN_PORT}/tcp 2>/dev/null || true
sleep 1

mkdir -p "${SRC_DIR}" "${CACHE_ROOT}"
ADMIN_TOKEN="$(cat ${INSTALL_DIR}/admin_token.txt)"

cat > "${SRC_DIR}/main.go" <<'GOEOF'
package main

import (
	"bufio"
	"bytes"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
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
var qualityFormats = map[string]string{"720": "best[height<=720]", "480": "best[height<=480]"}
var qualityBandwidth = map[string]int{"720": 2800000, "480": 1200000}
var qualityResolution = map[string]string{"720": "1280x720", "480": "854x480"}

type ContentItem struct {
	ID              string            `json:"id"`
	Name            string            `json:"name,omitempty"`
	Category        string            `json:"category,omitempty"`
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

type Library struct { mu sync.RWMutex; items map[string]*ContentItem }
func NewLibrary() *Library { return &Library{items: make(map[string]*ContentItem)} }
func (l *Library) Add(item *ContentItem) { l.mu.Lock(); defer l.mu.Unlock(); l.items[item.ID] = item }
func (l *Library) Get(id string) (*ContentItem, bool) { l.mu.RLock(); defer l.mu.RUnlock(); it, ok := l.items[id]; return it, ok }
func (l *Library) Delete(id string) bool { l.mu.Lock(); defer l.mu.Unlock(); _, ok := l.items[id]; if ok { delete(l.items, id) }; return ok }
func (l *Library) ListForClient() []ContentItem {
	l.mu.RLock(); defer l.mu.RUnlock(); out := make([]ContentItem, 0, len(l.items))
	for _, it := range l.items { out = append(out, ContentItem{ID: it.ID, Name: it.Name, Category: it.Category, URL: it.URL, Thumbnail: it.Thumbnail, DurationSeconds: it.DurationSeconds, IsLive: it.IsLive, Status: it.Status}) }; return out
}
func (l *Library) ListAll() []ContentItem {
	l.mu.RLock(); defer l.mu.RUnlock(); out := make([]ContentItem, 0, len(l.items))
	for _, it := range l.items { out = append(out, *it) }; return out
}
func (l *Library) Save() error {
	l.mu.RLock(); defer l.mu.RUnlock(); tmp := dataFile + ".tmp"; f, err := os.Create(tmp); if err != nil { return err }; enc := json.NewEncoder(f); enc.SetIndent("", "  ")
	all := make([]*ContentItem, 0, len(l.items)); for _, it := range l.items { all = append(all, it) }; if err := enc.Encode(all); err != nil { f.Close(); return err }; f.Close(); return os.Rename(tmp, dataFile)
}
func (l *Library) Load() error {
	data, err := os.ReadFile(dataFile); if err != nil { if os.IsNotExist(err) { return nil }; return err }
	var all []*ContentItem; if err := json.Unmarshal(data, &all); err != nil { return err }; l.mu.Lock(); defer l.mu.Unlock()
	for _, it := range all { if it.QualityDirs == nil { it.QualityDirs = make(map[string]string) }; if it.QualityReady == nil { it.QualityReady = make(map[string]bool) }; l.items[it.ID] = it }; return nil
}

type OnDemandManager struct { mu sync.RWMutex; lastAccessed map[string]time.Time; resolutions map[string]map[string]string; resTime map[string]time.Time }
func NewOnDemandManager() *OnDemandManager { m := &OnDemandManager{lastAccessed: make(map[string]time.Time), resolutions: make(map[string]map[string]string), resTime: make(map[string]time.Time)}; go m.cleanupRoutine(); return m }
func (m *OnDemandManager) Touch(id string) { m.mu.Lock(); defer m.mu.Unlock(); m.lastAccessed[id] = time.Now() }
func (m *OnDemandManager) cleanupRoutine() {
	for { time.Sleep(5 * time.Minute); m.mu.Lock(); for id, last := range m.lastAccessed { if time.Since(last) > 20*time.Minute { log.Printf("[ondemand] liberando ID: %s", id); os.RemoveAll(filepath.Join(cacheRoot, "ondemand_"+id)); delete(m.lastAccessed, id); delete(m.resolutions, id); delete(m.resTime, id) } }; m.mu.Unlock() }
}
func (m *OnDemandManager) getRemoteURL(id, sourceURL, quality string) (string, error) {
	m.mu.RLock(); cachedTime, timeOk := m.resTime[id]; urls, urlsOk := m.resolutions[id]; m.mu.RUnlock()
	if timeOk && urlsOk && time.Since(cachedTime) < 2*time.Hour { if u, ok := urls[quality]; ok && u != "" { return u, nil } }
	res, err := resolveDirectURL(sourceURL, qualityFormats[quality]); if err != nil { return "", err }
	m.mu.Lock(); if m.resolutions[id] == nil { m.resolutions[id] = make(map[string]string) }; m.resolutions[id][quality] = res; m.resTime[id] = time.Now(); m.mu.Unlock(); return res, nil
}

type LobbyClient struct { deviceID string; writer *bufio.Writer; mu sync.Mutex }
type LobbyHub struct { mu sync.Mutex; clients map[string]*LobbyClient }
func NewLobbyHub() *LobbyHub { return &LobbyHub{clients: make(map[string]*LobbyClient)} }
func (h *LobbyHub) Register(c *LobbyClient) { h.mu.Lock(); defer h.mu.Unlock(); h.clients[c.deviceID] = c }
func (h *LobbyHub) Unregister(deviceID string) { h.mu.Lock(); defer h.mu.Unlock(); delete(h.clients, deviceID) }
func (h *LobbyHub) BroadcastContentList(lib *Library) {
	msg := map[string]interface{}{"type": "content_list", "items": lib.ListForClient()}; data, _ := json.Marshal(msg); line := append(data, '\n')
	h.mu.Lock(); defer h.mu.Unlock()
	for id, c := range h.clients { c.mu.Lock(); _, err := c.writer.Write(line); if err == nil { err = c.writer.Flush() }; c.mu.Unlock(); if err != nil { delete(h.clients, id) } }
}
func sendLine(c *LobbyClient, v interface{}) { data, _ := json.Marshal(v); c.mu.Lock(); defer c.mu.Unlock(); c.writer.Write(data); c.writer.Write([]byte("\n")); c.writer.Flush() }
func startLobbyServer(lib *Library, hub *LobbyHub) {
	ln, err := net.Listen("tcp", ":"+lobbyPort); if err != nil { log.Fatalf("[lobby] error: %v", err) }; log.Printf("[lobby] en :%s", lobbyPort)
	for { conn, err := ln.Accept(); if err != nil { continue }; go handleLobbyConn(conn, lib, hub) }
}
func handleLobbyConn(conn net.Conn, lib *Library, hub *LobbyHub) {
	defer conn.Close(); reader := bufio.NewReader(conn); headers := make(map[string]string)
	requestLine, err := reader.ReadString('\n'); if err != nil || !strings.HasPrefix(requestLine, "GET ") { return }
	for { line, _ := reader.ReadString('\n'); line = strings.TrimRight(line, "\r\n"); if line == "" { break }; kv := strings.SplitN(line, ":", 2); if len(kv) == 2 { headers[strings.TrimSpace(strings.ToLower(kv[0]))] = strings.TrimSpace(kv[1]) } }
	deviceID := headers["x-device-id"]; if deviceID == "" { return }
	conn.Write([]byte("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n"))
	client := &LobbyClient{deviceID: deviceID, writer: bufio.NewWriter(conn)}; hub.Register(client); defer hub.Unregister(deviceID)
	sendLine(client, map[string]interface{}{"type": "state", "status": "ready"}); sendLine(client, map[string]interface{}{"type": "content_list", "items": lib.ListForClient()})
	for { line, err := reader.ReadString('\n'); if err != nil { return }; var msg map[string]interface{}; json.Unmarshal([]byte(line), &msg) }
}

func resolveDirectURL(sourceURL, format string) (string, error) {
	cmd := exec.Command("yt-dlp", "-g", "--no-playlist", "--quiet", "-f", format, sourceURL); var out bytes.Buffer; cmd.Stdout = &out; done := make(chan error, 1)
	if err := cmd.Start(); err != nil { return "", err }; go func() { done <- cmd.Wait() }()
	select { case err := <-done: if err != nil { return "", err }; case <-time.After(resolveTimeoutSec * time.Second): cmd.Process.Kill(); return "", fmt.Errorf("timeout") }
	line := strings.TrimSpace(out.String()); if line == "" { return "", fmt.Errorf("URL vacia") }; return strings.Split(line, "\n")[0], nil
}

type ytDlpMeta struct { Duration float64 `json:"duration"`; Thumbnail string `json:"thumbnail"` }
func resolveMetadata(sourceURL string) (*ytDlpMeta, error) {
	cmd := exec.Command("yt-dlp", "--no-playlist", "--quiet", "--dump-json", sourceURL); var out bytes.Buffer; cmd.Stdout = &out
	if err := cmd.Run(); err != nil { return nil, err }; var meta ytDlpMeta; if err := json.Unmarshal(out.Bytes(), &meta); err != nil { return nil, err }; return &meta, nil
}

func fetchBytes(url string) ([]byte, error) {
	req, err := http.NewRequest("GET", url, nil); if err != nil { return nil, err }
	req.Header.Set("User-Agent", "Mozilla/5.0"); client := &http.Client{Timeout: 20 * time.Second}
	resp, err := client.Do(req); if err != nil { return nil, err }; defer resp.Body.Close()
	if resp.StatusCode != 200 { return nil, fmt.Errorf("status %d", resp.StatusCode) }; return io.ReadAll(resp.Body)
}

func parseM3U8Segments(content, baseURL string) (int, []struct{ url string; dur float64 }) {
	lines := strings.Split(content, "\n"); targetDuration := 6; var segs []struct{ url string; dur float64 }; var pendingDur float64
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "#EXT-X-TARGETDURATION:") { v, _ := strconv.Atoi(strings.TrimPrefix(line, "#EXT-X-TARGETDURATION:")); if v > 0 { targetDuration = v }
		} else if strings.HasPrefix(line, "#EXTINF:") { v := strings.Split(strings.TrimPrefix(line, "#EXTINF:"), ",")[0]; f, _ := strconv.ParseFloat(v, 64); pendingDur = f
		} else if line != "" && !strings.HasPrefix(line, "#") {
			segURL := line; if !strings.HasPrefix(line, "http") { base := baseURL; if idx := strings.LastIndex(base, "?"); idx >= 0 { base = base[:idx] }; if idx := strings.LastIndex(base, "/"); idx >= 0 { base = base[:idx] }; segURL = base + "/" + line }
			dur := pendingDur; if dur == 0 { dur = 6.0 }; segs = append(segs, struct{ url string; dur float64 }{segURL, dur}); pendingDur = 0
		}
	}
	return targetDuration, segs
}

func processLibraryItem(lib *Library, hub *LobbyHub, item *ContentItem) {
	meta, err := resolveMetadata(item.SourceURL); if err == nil && meta != nil { if meta.Duration > 0 { d := int(meta.Duration); item.DurationSeconds = &d }; if meta.Thumbnail != "" { t := meta.Thumbnail; if item.Thumbnail == nil { item.Thumbnail = &t } } }
	itemDir := filepath.Join(cacheRoot, item.ID); os.MkdirAll(itemDir, 0o755); var wg sync.WaitGroup; var mu sync.Mutex; anyReady := false
	for _, quality := range qualities {
		format := qualityFormats[quality]; wg.Add(1)
		go func(quality, format string) {
			defer wg.Done(); m3u8URL, err := resolveDirectURL(item.SourceURL, format); if err != nil { return }
			qDir := filepath.Join(itemDir, quality); os.MkdirAll(qDir, 0o755); seen := map[string]bool{}; idx := 0; type segEntry struct{ fname string; dur float64 }; var allSegs []segEntry; targetDur := 6
			for {
				data, err := fetchBytes(m3u8URL); if err != nil { break }; content := string(data); td, segs := parseM3U8Segments(content, m3u8URL); targetDur = td; newSegs := 0
				for _, seg := range segs {
					if seen[seg.url] { continue }; seen[seg.url] = true; segData, err := fetchBytes(seg.url); if err != nil { continue }
					fname := fmt.Sprintf("seg_%08d.ts", idx); fpath := filepath.Join(qDir, fname); os.WriteFile(fpath, segData, 0o644)
					allSegs = append(allSegs, segEntry{fname, seg.dur}); idx++; newSegs++
				}
				if strings.Contains(content, "#EXT-X-ENDLIST") || (newSegs == 0 && len(segs) > 0) { break }; time.Sleep(segmentPollSec * time.Second)
			}
			if len(allSegs) == 0 { return }; playlistLines := []string{"#EXTM3U", "#EXT-X-VERSION:3", fmt.Sprintf("#EXT-X-TARGETDURATION:%d", targetDur), "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD"}
			for _, s := range allSegs { playlistLines = append(playlistLines, fmt.Sprintf("#EXTINF:%.3f,", s.dur), fmt.Sprintf("/hls/%s/%s/%s", item.ID, quality, s.fname)) }
			playlistLines = append(playlistLines, "#EXT-X-ENDLIST"); os.WriteFile(filepath.Join(qDir, "playlist.m3u8"), []byte(strings.Join(playlistLines, "\n")+"\n"), 0o644)
			mu.Lock(); item.QualityDirs[quality] = qDir; item.QualityReady[quality] = true; anyReady = true; mu.Unlock()
		}(quality, format)
	}
	wg.Wait(); if anyReady { item.URL = "/hls/" + item.ID + "/master.m3u8"; item.Status = "ready" } else { item.Status = "failed" }; lib.Save(); hub.BroadcastContentList(lib)
}

type LiveSegment struct{ fname string; dur float64 }
type LiveStream struct { mu sync.RWMutex; segments []LiveSegment; targetDur int; mediaSequence int; ready bool; stop chan struct{} }
type LiveManager struct { mu sync.Mutex; streams map[string]*LiveStream }
func NewLiveManager() *LiveManager { return &LiveManager{streams: make(map[string]*LiveStream)} }
func (m *LiveManager) GetOrCreate(id, sourceURL string) *LiveStream {
	m.mu.Lock(); defer m.mu.Unlock(); if ls, ok := m.streams[id]; ok { return ls }; ls := &LiveStream{targetDur: 6, stop: make(chan struct{})}; m.streams[id] = ls; go m.runLive(id, sourceURL, ls); return ls
}
func (m *LiveManager) Stop(id string) { m.mu.Lock(); defer m.mu.Unlock(); if ls, ok := m.streams[id]; ok { close(ls.stop); delete(m.streams, id) } }
func (m *LiveManager) runLive(id, sourceURL string, ls *LiveStream) {
	liveDir := filepath.Join(cacheRoot, "live_"+id); os.MkdirAll(liveDir, 0o755)
	m3u8URL, err := resolveDirectURL(sourceURL, "best[height<=720]/best"); if err != nil { return }; seen := map[string]bool{}; idx := 0
	for {
		select { case <-ls.stop: os.RemoveAll(liveDir); return; default: }
		data, err := fetchBytes(m3u8URL); if err != nil { time.Sleep(segmentPollSec * time.Second); continue }; td, segs := parseM3U8Segments(string(data), m3u8URL); ls.mu.Lock(); ls.targetDur = td; ls.mu.Unlock()
		for _, seg := range segs {
			if seen[seg.url] { continue }; seen[seg.url] = true; segData, err := fetchBytes(seg.url); if err != nil { continue }
			fname := fmt.Sprintf("seg_%08d.ts", idx); os.WriteFile(filepath.Join(liveDir, fname), segData, 0o644)
			ls.mu.Lock(); ls.segments = append(ls.segments, LiveSegment{fname: fname, dur: seg.dur})
			if len(ls.segments) > liveSegmentBuffer { old := ls.segments[0]; ls.segments = ls.segments[1:]; ls.mediaSequence++; os.Remove(filepath.Join(liveDir, old.fname)) }
			if !ls.ready && len(ls.segments) >= minSegmentsReady { ls.ready = true }; ls.mu.Unlock(); idx++
		}
		time.Sleep(segmentPollSec * time.Second)
	}
}

func startHTTPServer(lib *Library, lm *LiveManager, odm *OnDemandManager) {
	mux := http.NewServeMux()
	mux.HandleFunc("/hls/", func(w http.ResponseWriter, r *http.Request) {
		parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/hls/"), "/"); if len(parts) < 2 { http.NotFound(w, r); return }
		id := parts[0]; rest := strings.Join(parts[1:], "/"); item, ok := lib.Get(id); if !ok { http.NotFound(w, r); return }
		w.Header().Set("Access-Control-Allow-Origin", "*"); w.Header().Set("Cache-Control", "no-cache")

		if item.Mode == "ondemand" {
			odm.Touch(id)
			if rest == "master.m3u8" {
				lines := []string{"#EXTM3U", "#EXT-X-VERSION:3"}; for _, q := range qualities { lines = append(lines, fmt.Sprintf("#EXT-X-STREAM-INF:BANDWIDTH=%d,RESOLUTION=%s", qualityBandwidth[q], qualityResolution[q]), fmt.Sprintf("/hls/%s/%s/playlist.m3u8", id, q)) }
				w.Header().Set("Content-Type", "application/vnd.apple.mpegurl"); w.Write([]byte(strings.Join(lines, "\n") + "\n")); return
			}
			if strings.HasSuffix(rest, "playlist.m3u8") {
				q := strings.Split(rest, "/")[0]; remoteURL, err := odm.getRemoteURL(id, item.SourceURL, q); if err != nil { http.Error(w, "error resolving", 500); return }
				data, err := fetchBytes(remoteURL); if err != nil { http.Error(w, "error fetching", 502); return }; lines := strings.Split(string(data), "\n")
				for i, line := range lines { line = strings.TrimSpace(line); if line != "" && !strings.HasPrefix(line, "#") { absURL := line; if !strings.HasPrefix(line, "http") { base := remoteURL; if idx := strings.LastIndex(base, "?"); idx >= 0 { base = base[:idx] }; if idx := strings.LastIndex(base, "/"); idx >= 0 { base = base[:idx] }; absURL = base + "/" + line }; lines[i] = fmt.Sprintf("/hls/%s/proxy/seg?url=%s", id, url.QueryEscape(absURL)) } }
				w.Header().Set("Content-Type", "application/vnd.apple.mpegurl"); w.Write([]byte(strings.Join(lines, "\n") + "\n")); return
			}
			if strings.HasPrefix(rest, "proxy/seg") {
				targetURL := r.URL.Query().Get("url"); if targetURL == "" { http.Error(w, "missing url", 400); return }
				hash := md5.Sum([]byte(targetURL)); hashStr := hex.EncodeToString(hash[:]); odDir := filepath.Join(cacheRoot, "ondemand_"+id); os.MkdirAll(odDir, 0o755); fpath := filepath.Join(odDir, hashStr+".ts")
				data, err := os.ReadFile(fpath); if err == nil { w.Header().Set("Content-Type", "video/MP2T"); w.Header().Set("Content-Length", strconv.Itoa(len(data))); w.Write(data); return }
				data, err = fetchBytes(targetURL); if err != nil { http.Error(w, "fetch fail", 502); return }; os.WriteFile(fpath, data, 0o644); w.Header().Set("Content-Type", "video/MP2T"); w.Header().Set("Content-Length", strconv.Itoa(len(data))); w.Write(data); return
			}
			http.NotFound(w, r); return
		}

		if item.IsLive {
			ls := lm.GetOrCreate(id, item.SourceURL)
			if rest == "master.m3u8" { ls.mu.RLock(); ready := ls.ready; ls.mu.RUnlock(); if !ready { http.Error(w, "no listo", 503); return }; w.Header().Set("Content-Type", "application/vnd.apple.mpegurl"); w.Write([]byte(fmt.Sprintf("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720\n/hls/%s/live.m3u8\n", id))); return }
			if rest == "live.m3u8" { ls.mu.RLock(); segs := make([]LiveSegment, len(ls.segments)); copy(segs, ls.segments); seq := ls.mediaSequence; td := ls.targetDur; ready := ls.ready; ls.mu.RUnlock(); if !ready { http.Error(w, "no listo", 503); return }; lines := []string{"#EXTM3U", "#EXT-X-VERSION:3", fmt.Sprintf("#EXT-X-TARGETDURATION:%d", td), fmt.Sprintf("#EXT-X-MEDIA-SEQUENCE:%d", seq)}; for _, s := range segs { lines = append(lines, fmt.Sprintf("#EXTINF:%.3f,", s.dur), fmt.Sprintf("/hls/%s/seg/%s", id, s.fname)) }; w.Header().Set("Content-Type", "application/vnd.apple.mpegurl"); w.Write([]byte(strings.Join(lines, "\n") + "\n")); return }
			if strings.HasPrefix(rest, "seg/") { fname := strings.TrimPrefix(rest, "seg/"); if strings.Contains(fname, "..") { http.NotFound(w, r); return }; data, err := os.ReadFile(filepath.Join(cacheRoot, "live_"+id, fname)); if err != nil { http.NotFound(w, r); return }; w.Header().Set("Content-Type", "video/MP2T"); w.Header().Set("Content-Length", strconv.Itoa(len(data))); w.Write(data); return }
			http.NotFound(w, r); return
		}

		if rest == "master.m3u8" { lines := []string{"#EXTM3U", "#EXT-X-VERSION:3"}; for _, q := range qualities { if !item.QualityReady[q] { continue }; lines = append(lines, fmt.Sprintf("#EXT-X-STREAM-INF:BANDWIDTH=%d,RESOLUTION=%s", qualityBandwidth[q], qualityResolution[q]), fmt.Sprintf("/hls/%s/%s/playlist.m3u8", id, q)) }; w.Header().Set("Content-Type", "application/vnd.apple.mpegurl"); w.Write([]byte(strings.Join(lines, "\n") + "\n")); return }
		if len(parts) >= 3 { quality := parts[1]; fname := parts[2]; if strings.Contains(fname, "..") { http.NotFound(w, r); return }; qDir, ok := item.QualityDirs[quality]; if !ok { http.NotFound(w, r); return }; data, err := os.ReadFile(filepath.Join(qDir, fname)); if err != nil { http.NotFound(w, r); return }; if strings.HasSuffix(fname, ".m3u8") { w.Header().Set("Content-Type", "application/vnd.apple.mpegurl") }; if strings.HasSuffix(fname, ".ts") { w.Header().Set("Content-Type", "video/MP2T"); w.Header().Set("Content-Length", strconv.Itoa(len(data))) }; w.Write(data); return }
		http.NotFound(w, r)
	})

	srv := &http.Server{Addr: ":" + httpPort, Handler: mux}; log.Fatal(srv.ListenAndServe())
}

func withAuth(token string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*"); w.Header().Set("Access-Control-Allow-Methods", "POST, GET, OPTIONS"); w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Admin-Token")
		if r.Method == "OPTIONS" { w.WriteHeader(http.StatusOK); return }
		if r.Header.Get("X-Admin-Token") != token { http.Error(w, `{"error":"Token Incorrecto"}`, http.StatusUnauthorized); return }
		next(w, r)
	}
}

func parseBodyVerbose(w http.ResponseWriter, r *http.Request, dest interface{}) error {
	bodyBytes, err := io.ReadAll(r.Body)
	if err != nil { http.Error(w, fmt.Sprintf("Error leyendo body: %v", err), 400); return err }
	if len(bodyBytes) == 0 { http.Error(w, "Body Vacio", 400); return fmt.Errorf("body vacio") }
	if err := json.Unmarshal(bodyBytes, dest); err != nil { http.Error(w, fmt.Sprintf("JSON malformado: %v", err), 400); return err }
	return nil
}

// Estructura actualizada con Thumbnail y IsLive
type AddReq struct {
	Name      string `json:"name"`
	URL       string `json:"url"`
	SourceURL string `json:"source_url"`
	Category  string `json:"category"`
	Duration  int    `json:"duration"`
	ID        string `json:"id"`
	Thumbnail string `json:"thumbnail"`
	IsLive    bool   `json:"is_live"`
}

func startAdminServer(lib *Library, hub *LobbyHub, lm *LiveManager, token string) {
	mux := http.NewServeMux()

	mux.HandleFunc("/admin/add-manual", withAuth(token, func(w http.ResponseWriter, r *http.Request) {
		var req AddReq; if err := parseBodyVerbose(w, r, &req); err != nil { return }
		if req.Name == "" || req.URL == "" { http.Error(w, fmt.Sprintf("Falta URL o Nombre"), 400); return }
		id := uuid.NewString(); item := &ContentItem{ID: id, Name: req.Name, Category: req.Category, URL: req.URL, Status: "ready", Mode: "manual", IsLive: req.IsLive}
		if req.Duration > 0 { item.DurationSeconds = &req.Duration }; if req.Thumbnail != "" { item.Thumbnail = &req.Thumbnail }
		lib.Add(item); lib.Save(); hub.BroadcastContentList(lib); json.NewEncoder(w).Encode(map[string]string{"id": id, "status": "ready"})
	}))

	mux.HandleFunc("/admin/add-library", withAuth(token, func(w http.ResponseWriter, r *http.Request) {
		var req AddReq; if err := parseBodyVerbose(w, r, &req); err != nil { return }
		if req.Name == "" || req.SourceURL == "" { http.Error(w, fmt.Sprintf("Falta URL o Nombre"), 400); return }
		id := uuid.NewString(); item := &ContentItem{ID: id, Name: req.Name, Category: req.Category, SourceURL: req.SourceURL, Status: "processing", Mode: "library", QualityDirs: make(map[string]string), QualityReady: make(map[string]bool)}
		if req.Thumbnail != "" { item.Thumbnail = &req.Thumbnail }
		lib.Add(item); lib.Save(); hub.BroadcastContentList(lib); go processLibraryItem(lib, hub, item)
		json.NewEncoder(w).Encode(map[string]string{"id": id, "status": "processing"})
	}))

	mux.HandleFunc("/admin/add-ondemand", withAuth(token, func(w http.ResponseWriter, r *http.Request) {
		var req AddReq; if err := parseBodyVerbose(w, r, &req); err != nil { return }
		if req.Name == "" || req.SourceURL == "" { http.Error(w, fmt.Sprintf("Falta URL o Nombre"), 400); return }
		id := uuid.NewString(); item := &ContentItem{ID: id, Name: req.Name, Category: req.Category, SourceURL: req.SourceURL, URL: "/hls/" + id + "/master.m3u8", Status: "ready", Mode: "ondemand"}
		if req.Thumbnail != "" { item.Thumbnail = &req.Thumbnail }
		lib.Add(item); lib.Save(); hub.BroadcastContentList(lib); json.NewEncoder(w).Encode(map[string]string{"id": id, "status": "ready"})
	}))

	mux.HandleFunc("/admin/add-live", withAuth(token, func(w http.ResponseWriter, r *http.Request) {
		var req AddReq; if err := parseBodyVerbose(w, r, &req); err != nil { return }
		if req.Name == "" || req.SourceURL == "" { http.Error(w, fmt.Sprintf("Falta URL o Nombre"), 400); return }
		id := uuid.NewString(); item := &ContentItem{ID: id, Name: req.Name, Category: req.Category, SourceURL: req.SourceURL, URL: "/hls/" + id + "/master.m3u8", Status: "ready", Mode: "live", IsLive: true}
		if req.Thumbnail != "" { item.Thumbnail = &req.Thumbnail }
		lib.Add(item); lib.Save(); hub.BroadcastContentList(lib); json.NewEncoder(w).Encode(map[string]string{"id": id, "status": "ready"})
	}))

	mux.HandleFunc("/admin/delete", withAuth(token, func(w http.ResponseWriter, r *http.Request) {
		var req AddReq; if err := parseBodyVerbose(w, r, &req); err != nil { return }
		item, ok := lib.Get(req.ID); if !ok { http.Error(w, "ID no encontrado en DB", 404); return }
		if item.IsLive && item.Mode == "live" { lm.Stop(req.ID) }; lib.Delete(req.ID); os.RemoveAll(filepath.Join(cacheRoot, req.ID)); os.RemoveAll(filepath.Join(cacheRoot, "ondemand_"+req.ID)); lib.Save(); hub.BroadcastContentList(lib)
		json.NewEncoder(w).Encode(map[string]string{"status": "deleted"})
	}))

	mux.HandleFunc("/admin/retry", withAuth(token, func(w http.ResponseWriter, r *http.Request) {
		var req AddReq; if err := parseBodyVerbose(w, r, &req); err != nil { return }
		item, ok := lib.Get(req.ID); if !ok { http.Error(w, "ID no encontrado", 404); return }
		if item.Mode != "library" { http.Error(w, "Solo videos de tipo Libreria pueden reintentarse", 400); return }
		item.Status = "processing"; item.QualityDirs = make(map[string]string); item.QualityReady = make(map[string]bool); os.RemoveAll(filepath.Join(cacheRoot, item.ID)); lib.Save(); hub.BroadcastContentList(lib); go processLibraryItem(lib, hub, item)
		json.NewEncoder(w).Encode(map[string]string{"status": "processing"})
	}))

	mux.HandleFunc("/admin/list", withAuth(token, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json"); json.NewEncoder(w).Encode(lib.ListAll())
	}))

	srv := &http.Server{Addr: "0.0.0.0:" + adminPort, Handler: mux}; log.Fatal(srv.ListenAndServe())
}

func main() {
	token := os.Getenv("ADMIN_TOKEN")
	if token == "" { data, _ := os.ReadFile("/opt/streamserver/admin_token.txt"); token = strings.TrimSpace(string(data)) }
	lib := NewLibrary(); lib.Load(); hub := NewLobbyHub(); lm := NewLiveManager(); odm := NewOnDemandManager()
	for _, it := range lib.ListAll() { if it.Mode == "library" && it.Status == "processing" { item, _ := lib.Get(it.ID); item.QualityDirs = make(map[string]string); item.QualityReady = make(map[string]bool); go processLibraryItem(lib, hub, item) } }
	sig := make(chan os.Signal, 1); signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT); go func() { <-sig; lib.Save(); os.Exit(0) }()
	go startAdminServer(lib, hub, lm, token); go startHTTPServer(lib, lm, odm); startLobbyServer(lib, hub)
}
GOEOF

echo "[2/4] Compilando e instalando..."
cd "${SRC_DIR}"
export PATH="/usr/local/go/bin:${PATH}"
go build -o "${INSTALL_DIR}/streamserver" .

echo "[3/4] Reiniciando servidor..."
systemctl restart "${SERVICE_NAME}"

echo "[4/4] Finalizado con Exito."
