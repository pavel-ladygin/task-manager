package stt

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const yandexEndpoint = "https://stt.api.cloud.yandex.net/speech/v1/stt:recognize"

type Yandex struct {
	APIKey     string
	FolderID   string
	Endpoint   string
	HTTPClient *http.Client
}

func (yandex *Yandex) Transcribe(ctx context.Context, ogg []byte) (string, error) {
	if yandex == nil || yandex.APIKey == "" || yandex.FolderID == "" {
		return "", errors.New("yandex API key and folder ID are required")
	}
	endpoint := yandex.Endpoint
	if endpoint == "" {
		endpoint = yandexEndpoint
	}
	parsedURL, err := url.Parse(endpoint)
	if err != nil {
		return "", err
	}
	query := parsedURL.Query()
	query.Set("folderId", yandex.FolderID)
	query.Set("lang", "ru-RU")
	query.Set("format", "oggopus")
	query.Set("topic", "general")
	query.Set("rawResults", "false")
	parsedURL.RawQuery = query.Encode()

	request, err := http.NewRequestWithContext(ctx, http.MethodPost, parsedURL.String(), bytes.NewReader(ogg))
	if err != nil {
		return "", err
	}
	request.Header.Set("Authorization", "Api-Key "+yandex.APIKey)
	request.Header.Set("Content-Type", "application/octet-stream")
	request.Header.Set("x-data-logging-enabled", "false")
	client := yandex.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 12 * time.Second}
	}
	response, err := client.Do(request)
	if err != nil {
		return "", &ProviderError{Provider: "yandex", Temporary: true}
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
		return "", &ProviderError{
			Provider:   "yandex",
			StatusCode: response.StatusCode,
			Temporary:  response.StatusCode == http.StatusRequestTimeout || response.StatusCode == http.StatusTooManyRequests || response.StatusCode >= 500,
			RetryAfter: retryAfter(response.Header.Get("Retry-After")),
		}
	}
	var decoded struct {
		Result string `json:"result"`
	}
	decoder := json.NewDecoder(io.LimitReader(response.Body, 1<<20))
	if err := decoder.Decode(&decoded); err != nil {
		return "", &ProviderError{Provider: "yandex", Temporary: true}
	}
	decoded.Result = strings.TrimSpace(decoded.Result)
	if decoded.Result == "" {
		return "", &ProviderError{Provider: "yandex", Temporary: false}
	}
	return decoded.Result, nil
}
