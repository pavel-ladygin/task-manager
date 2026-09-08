package telegrambot

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"path"
	"strings"
	"time"
)

var (
	ErrVoiceTooLarge = errors.New("voice message is too large")
	ErrInvalidVoice  = errors.New("invalid voice message")
)

type API interface {
	DownloadVoice(ctx context.Context, fileID string, maximumBytes int64) ([]byte, error)
	SendMessage(ctx context.Context, chatID int64, text string) error
}

type Client struct {
	token      string
	baseURL    string
	httpClient *http.Client
}

func NewClient(token string) *Client {
	return &Client{
		token:   token,
		baseURL: "https://api.telegram.org",
		httpClient: &http.Client{
			Timeout: 12 * time.Second,
			CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}
}

func newClientForTest(token string, baseURL string, httpClient *http.Client) *Client {
	return &Client{token: token, baseURL: strings.TrimRight(baseURL, "/"), httpClient: httpClient}
}

func (client *Client) SendMessage(ctx context.Context, chatID int64, text string) error {
	payload := map[string]any{
		"chat_id":                  chatID,
		"text":                     truncateRunes(text, 4096),
		"disable_web_page_preview": true,
	}
	var result json.RawMessage
	return client.call(ctx, "sendMessage", payload, &result)
}

func (client *Client) DownloadVoice(ctx context.Context, fileID string, maximumBytes int64) ([]byte, error) {
	if fileID == "" || maximumBytes <= 0 {
		return nil, ErrInvalidVoice
	}
	var file struct {
		FilePath string `json:"file_path"`
		FileSize int64  `json:"file_size,omitempty"`
	}
	if err := client.call(ctx, "getFile", map[string]string{"file_id": fileID}, &file); err != nil {
		return nil, err
	}
	if file.FileSize > maximumBytes {
		return nil, ErrVoiceTooLarge
	}
	cleanPath := path.Clean("/" + file.FilePath)
	if file.FilePath == "" || strings.HasPrefix(file.FilePath, "/") || strings.Contains(file.FilePath, "://") || strings.Contains(file.FilePath, "..") || strings.Contains(cleanPath, "..") {
		return nil, ErrInvalidVoice
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, client.baseURL+"/file/bot"+client.token+cleanPath, nil)
	if err != nil {
		return nil, ErrInvalidVoice
	}
	response, err := client.httpClient.Do(request)
	if err != nil {
		return nil, errors.New("telegram file download failed")
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
		return nil, fmt.Errorf("telegram file download failed with status %d", response.StatusCode)
	}
	if response.ContentLength > maximumBytes {
		return nil, ErrVoiceTooLarge
	}
	audio, err := io.ReadAll(io.LimitReader(response.Body, maximumBytes+1))
	if err != nil {
		return nil, errors.New("telegram file download failed")
	}
	if int64(len(audio)) > maximumBytes {
		return nil, ErrVoiceTooLarge
	}
	if len(audio) < 4 || string(audio[:4]) != "OggS" {
		return nil, ErrInvalidVoice
	}
	return audio, nil
}

func (client *Client) call(ctx context.Context, method string, payload any, result any) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, client.baseURL+"/bot"+client.token+"/"+method, bytes.NewReader(body))
	if err != nil {
		return errors.New("telegram request could not be created")
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := client.httpClient.Do(request)
	if err != nil {
		return errors.New("telegram API request failed")
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
		return fmt.Errorf("telegram API request failed with status %d", response.StatusCode)
	}
	var envelope struct {
		OK     bool            `json:"ok"`
		Result json.RawMessage `json:"result"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&envelope); err != nil || !envelope.OK {
		return errors.New("telegram API returned an invalid response")
	}
	if result != nil && len(envelope.Result) > 0 && string(envelope.Result) != "true" {
		if err := json.Unmarshal(envelope.Result, result); err != nil {
			return errors.New("telegram API returned an invalid result")
		}
	}
	return nil
}

func truncateRunes(value string, maximum int) string {
	runes := []rune(value)
	if len(runes) <= maximum {
		return value
	}
	if maximum <= 1 {
		return string(runes[:maximum])
	}
	return string(runes[:maximum-1]) + "…"
}
