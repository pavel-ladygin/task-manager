package telegrambot

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Enabled       bool
	BotToken      string
	BotID         string
	WebhookSecret string
	AllowedUserID int64
	Location      *time.Location
	STTPrimary    string
	STTFallback   string
	GroqAPIKey    string
	GroqModel     string
	YandexAPIKey  string
	YandexFolder  string
}

func LoadConfig(getenv func(string) string) (Config, error) {
	if getenv == nil {
		return Config{}, errors.New("environment reader is required")
	}
	enabledText := strings.TrimSpace(getenv("PLANNER_TELEGRAM_ENABLED"))
	if enabledText == "" {
		enabledText = "false"
	}
	enabled, err := strconv.ParseBool(enabledText)
	if err != nil {
		return Config{}, errors.New("PLANNER_TELEGRAM_ENABLED must be true or false")
	}
	config := Config{Enabled: enabled}
	if !enabled {
		return config, nil
	}

	config.BotToken = strings.TrimSpace(getenv("TELEGRAM_BOT_TOKEN"))
	config.WebhookSecret = strings.TrimSpace(getenv("TELEGRAM_WEBHOOK_SECRET"))
	userIDText := strings.TrimSpace(getenv("TELEGRAM_ALLOWED_USER_ID"))
	zoneName := strings.TrimSpace(getenv("PLANNER_TIMEZONE"))
	if zoneName == "" {
		zoneName = "Europe/Moscow"
	}
	config.STTPrimary = strings.ToLower(strings.TrimSpace(getenv("STT_PRIMARY")))
	if config.STTPrimary == "" {
		config.STTPrimary = "groq"
	}
	config.STTFallback = strings.ToLower(strings.TrimSpace(getenv("STT_FALLBACK")))
	if config.STTFallback == "" {
		config.STTFallback = "none"
	}
	config.GroqAPIKey = strings.TrimSpace(getenv("GROQ_API_KEY"))
	config.GroqModel = strings.TrimSpace(getenv("GROQ_STT_MODEL"))
	if config.GroqModel == "" {
		config.GroqModel = "whisper-large-v3"
	}
	config.YandexAPIKey = strings.TrimSpace(getenv("YANDEX_API_KEY"))
	config.YandexFolder = strings.TrimSpace(getenv("YANDEX_FOLDER_ID"))

	if config.BotToken == "" || config.WebhookSecret == "" || userIDText == "" {
		return Config{}, errors.New("TELEGRAM_BOT_TOKEN, TELEGRAM_WEBHOOK_SECRET and TELEGRAM_ALLOWED_USER_ID are required when Telegram is enabled")
	}
	colon := strings.IndexByte(config.BotToken, ':')
	if colon <= 0 {
		return Config{}, errors.New("TELEGRAM_BOT_TOKEN has an invalid format")
	}
	config.BotID = config.BotToken[:colon]
	if _, err := strconv.ParseInt(config.BotID, 10, 64); err != nil {
		return Config{}, errors.New("TELEGRAM_BOT_TOKEN has an invalid bot ID")
	}
	if len(config.WebhookSecret) < 16 || len(config.WebhookSecret) > 256 {
		return Config{}, errors.New("TELEGRAM_WEBHOOK_SECRET must contain between 16 and 256 characters")
	}
	for _, value := range config.WebhookSecret {
		if !((value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') || (value >= '0' && value <= '9') || value == '_' || value == '-') {
			return Config{}, errors.New("TELEGRAM_WEBHOOK_SECRET may contain only letters, digits, underscores and hyphens")
		}
	}
	config.AllowedUserID, err = strconv.ParseInt(userIDText, 10, 64)
	if err != nil || config.AllowedUserID <= 0 {
		return Config{}, errors.New("TELEGRAM_ALLOWED_USER_ID must be a positive integer")
	}
	config.Location, err = time.LoadLocation(zoneName)
	if err != nil {
		return Config{}, fmt.Errorf("load PLANNER_TIMEZONE: %w", err)
	}
	if config.STTPrimary != "groq" {
		return Config{}, errors.New("STT_PRIMARY must be groq")
	}
	if config.GroqAPIKey == "" {
		return Config{}, errors.New("GROQ_API_KEY is required when Telegram voice input is enabled")
	}
	if config.STTFallback != "none" && config.STTFallback != "yandex" {
		return Config{}, errors.New("STT_FALLBACK must be none or yandex")
	}
	if config.STTFallback == "yandex" && (config.YandexAPIKey == "" || config.YandexFolder == "") {
		return Config{}, errors.New("YANDEX_API_KEY and YANDEX_FOLDER_ID are required for the Yandex fallback")
	}
	return config, nil
}
