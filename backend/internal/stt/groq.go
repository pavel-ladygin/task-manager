package stt

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime/multipart"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const groqEndpoint = "https://api.groq.com/openai/v1/audio/transcriptions"

type Groq struct {
	APIKey     string
	Model      string
	Endpoint   string
	HTTPClient *http.Client
}

func (groq *Groq) Transcribe(ctx context.Context, ogg []byte) (string, error) {
	if groq == nil || groq.APIKey == "" {
		return "", errors.New("groq API key is not configured")
	}
	endpoint := groq.Endpoint
	if endpoint == "" {
		endpoint = groqEndpoint
	}
	model := groq.Model
	if model == "" {
		model = "whisper-large-v3"
	}
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	file, err := writer.CreateFormFile("file", "voice.ogg")
	if err != nil {
		return "", err
	}
	if _, err := file.Write(ogg); err != nil {
		return "", err
	}
	fields := map[string]string{
		"model":           model,
		"language":        "ru",
		"temperature":     "0",
		"response_format": "json",
		"prompt":          "Русская команда планировщика. Даты: сегодня, завтра, послезавтра. Время записывай цифрами в формате HH:MM.",
	}
	for name, value := range fields {
		if err := writer.WriteField(name, value); err != nil {
			return "", err
		}
	}
	if err := writer.Close(); err != nil {
		return "", err
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, &body)
	if err != nil {
		return "", err
	}
	request.Header.Set("Authorization", "Bearer "+groq.APIKey)
	request.Header.Set("Content-Type", writer.FormDataContentType())
	client := groq.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 12 * time.Second}
	}
	response, err := client.Do(request)
	if err != nil {
		return "", &ProviderError{Provider: "groq", Temporary: true}
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
		return "", &ProviderError{
			Provider:   "groq",
			StatusCode: response.StatusCode,
			Temporary:  response.StatusCode == http.StatusRequestTimeout || response.StatusCode == http.StatusTooManyRequests || response.StatusCode >= 500,
			RetryAfter: retryAfter(response.Header.Get("Retry-After")),
		}
	}
	var decoded struct {
		Text string `json:"text"`
	}
	decoder := json.NewDecoder(io.LimitReader(response.Body, 1<<20))
	if err := decoder.Decode(&decoded); err != nil {
		return "", &ProviderError{Provider: "groq", Temporary: true}
	}
	decoded.Text = strings.TrimSpace(decoded.Text)
	if decoded.Text == "" {
		return "", &ProviderError{Provider: "groq", Temporary: false}
	}
	return decoded.Text, nil
}

func retryAfter(value string) time.Duration {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0
	}
	if seconds, err := strconv.Atoi(value); err == nil && seconds >= 0 {
		return time.Duration(seconds) * time.Second
	}
	if date, err := http.ParseTime(value); err == nil {
		if duration := time.Until(date); duration > 0 {
			return duration
		}
	}
	return 0
}
