package main

import (
	"crypto/tls"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"time"
)

func env(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}

func main() {
	listenAddr := env("GATEWAY_LISTEN_ADDR", ":443")
	basePath := env("BASE_PATH", "/recargas")
	upstream := env("UPSTREAM_URL", "http://127.0.0.1:3000")
	certPath := env("SSL_CERT_PATH", "")
	keyPath := env("SSL_KEY_PATH", "")

	if certPath == "" || keyPath == "" {
		log.Fatal("SSL_CERT_PATH y SSL_KEY_PATH son obligatorios para el gateway TLS")
	}

	target, err := url.Parse(upstream)
	if err != nil {
		log.Fatalf("UPSTREAM_URL inválido: %v", err)
	}

	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		http.Error(w, "Servicio temporalmente no disponible", http.StatusBadGateway)
	}

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			http.Redirect(w, r, strings.TrimRight(basePath, "/"), http.StatusFound)
			return
		}

		if !strings.HasPrefix(r.URL.Path, basePath) {
			http.NotFound(w, r)
			return
		}

		newPath := strings.TrimPrefix(r.URL.Path, basePath)
		if newPath == "" {
			newPath = "/"
		}

		r.URL.Path = newPath
		r.URL.RawPath = newPath
		r.Host = target.Host
		proxy.ServeHTTP(w, r)
	})

	srv := &http.Server{
		Addr:              listenAddr,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       20 * time.Second,
		WriteTimeout:      20 * time.Second,
		IdleTimeout:       60 * time.Second,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
		},
	}

	log.Printf("Gateway HTTPS escuchando en %s, basePath=%s, upstream=%s", listenAddr, basePath, upstream)
	log.Fatal(srv.ListenAndServeTLS(certPath, keyPath))
}
