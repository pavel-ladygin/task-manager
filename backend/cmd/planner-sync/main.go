package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
	_ "time/tzdata"

	"planner-sync/internal/server"
	"planner-sync/internal/store"
	"planner-sync/internal/stt"
	"planner-sync/internal/telegrambot"
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
	telegramConfig, err := telegrambot.LoadConfig(os.Getenv)
	if err != nil {
		log.Fatalf("telegram configuration: %v", err)
	}

	syncStore, err := store.Open(dbPath)
	if err != nil {
		log.Fatalf("open store: %v", err)
	}
	defer syncStore.Close()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	router := http.NewServeMux()
	router.Handle("/", server.New(syncStore, token, widgetToken))
	if telegramConfig.Enabled {
		telegramAPI := telegrambot.NewClient(telegramConfig.BotToken)
		var fallback stt.Transcriber
		if telegramConfig.STTFallback == "yandex" {
			fallback = &stt.Yandex{APIKey: telegramConfig.YandexAPIKey, FolderID: telegramConfig.YandexFolder}
		}
		transcriber := stt.Chain{
			Primary:  &stt.Groq{APIKey: telegramConfig.GroqAPIKey, Model: telegramConfig.GroqModel},
			Fallback: fallback,
		}
		worker := telegrambot.NewWorker(
			syncStore,
			telegramAPI,
			transcriber,
			telegrambot.NewTaskCreator(syncStore),
			telegramConfig.BotID,
			telegramConfig.Location,
			log.Default(),
		)
		router.Handle("POST /telegram/webhook", telegrambot.NewHandler(
			syncStore,
			telegramConfig.BotID,
			telegramConfig.WebhookSecret,
			telegramConfig.AllowedUserID,
			worker.Notify,
		))
		go worker.Run(ctx)
		notifier := telegrambot.NewNotifier(
			syncStore,
			telegramAPI,
			telegramConfig.BotID,
			telegramConfig.AllowedUserID,
			telegramConfig.Location,
			log.Default(),
		)
		go notifier.Run(ctx)
		log.Printf("telegram input and notifications enabled for bot_id=%s", telegramConfig.BotID)
	}

	httpServer := &http.Server{
		Addr:              addr,
		Handler:           router,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}

	log.Printf("planner sync listening on %s", addr)
	serverErrors := make(chan error, 1)
	go func() {
		serverErrors <- httpServer.ListenAndServeTLS(certPath, keyPath)
	}()
	select {
	case err := <-serverErrors:
		if !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	case <-ctx.Done():
		shutdownContext, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(shutdownContext); err != nil {
			log.Printf("http shutdown: %v", err)
		}
	}
}

func env(key string, fallback string) string {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	return value
}
