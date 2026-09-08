package telegrambot

import "testing"

func TestLoadConfigDisabledByDefault(t *testing.T) {
	config, err := LoadConfig(func(string) string { return "" })
	if err != nil || config.Enabled {
		t.Fatalf("LoadConfig() = %+v, %v", config, err)
	}
}

func TestLoadConfigEnabled(t *testing.T) {
	values := map[string]string{
		"PLANNER_TELEGRAM_ENABLED": "true",
		"TELEGRAM_BOT_TOKEN":       "123456:token",
		"TELEGRAM_WEBHOOK_SECRET":  "0123456789abcdef",
		"TELEGRAM_ALLOWED_USER_ID": "42",
		"GROQ_API_KEY":             "groq-secret",
	}
	config, err := LoadConfig(func(key string) string { return values[key] })
	if err != nil {
		t.Fatal(err)
	}
	if !config.Enabled || config.BotID != "123456" || config.AllowedUserID != 42 || config.STTPrimary != "groq" || config.STTFallback != "none" || config.GroqModel != "whisper-large-v3" {
		t.Fatalf("unexpected config: %+v", config)
	}
	if config.Location == nil || config.Location.String() != "Europe/Moscow" {
		t.Fatalf("unexpected location: %v", config.Location)
	}
}

func TestLoadConfigRequiresYandexCredentials(t *testing.T) {
	values := map[string]string{
		"PLANNER_TELEGRAM_ENABLED": "true",
		"TELEGRAM_BOT_TOKEN":       "123456:token",
		"TELEGRAM_WEBHOOK_SECRET":  "0123456789abcdef",
		"TELEGRAM_ALLOWED_USER_ID": "42",
		"GROQ_API_KEY":             "groq-secret",
		"STT_FALLBACK":             "yandex",
	}
	if _, err := LoadConfig(func(key string) string { return values[key] }); err == nil {
		t.Fatal("expected missing Yandex credentials to fail")
	}
}
