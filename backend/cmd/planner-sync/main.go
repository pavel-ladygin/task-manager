package main

import (
	"log"
	"net/http"
	"os"
	"time"

	"planner-sync/internal/server"
	"planner-sync/internal/store"
)

func main() {
	dbPath := env("PLANNER_DB_PATH", "/data/planner.db")
	addr := env("PLANNER_ADDR", ":443")
	certPath := env("PLANNER_TLS_CERT", "/certs/planner.crt")
	keyPath := env("PLANNER_TLS_KEY", "/certs/planner.key")
	token := os.Getenv("PLANNER_SYNC_TOKEN")
	if token == "" {
		log.Fatal("PLANNER_SYNC_TOKEN is required")
	}
	widgetToken := os.Getenv("PLANNER_WIDGET_TOKEN")
	if len(widgetToken) < 32 {
		log.Fatal("PLANNER_WIDGET_TOKEN must contain at least 32 characters")
	}
	if widgetToken == token {
		log.Fatal("PLANNER_WIDGET_TOKEN must differ from PLANNER_SYNC_TOKEN")
	}

	syncStore, err := store.Open(dbPath)
	if err != nil {
		log.Fatalf("open store: %v", err)
	}
	defer syncStore.Close()

	handler := server.New(syncStore, token, widgetToken)
	httpServer := &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}

	log.Printf("planner sync listening on %s", addr)
	if err := httpServer.ListenAndServeTLS(certPath, keyPath); err != nil {
		log.Fatal(err)
	}
}

func env(key string, fallback string) string {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	return value
}
