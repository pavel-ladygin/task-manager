package telegrambot

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestClientDownloadsVoiceAndSendsMessage(t *testing.T) {
	var sentText string
	transport := telegramRoundTripFunc(func(request *http.Request) (*http.Response, error) {
		switch request.URL.Path {
		case "/botsecret/getFile":
			return telegramJSONResponse(http.StatusOK, map[string]any{
				"ok": true, "result": map[string]any{"file_path": "voice/file.oga", "file_size": 9},
			}), nil
		case "/file/botsecret/voice/file.oga":
			return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader("OggSvoice")), Header: make(http.Header)}, nil
		case "/botsecret/sendMessage":
			var payload struct {
				ChatID int64  `json:"chat_id"`
				Text   string `json:"text"`
			}
			if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
				t.Fatal(err)
			}
			if payload.ChatID != 42 {
				t.Fatalf("chat ID = %d", payload.ChatID)
			}
			sentText = payload.Text
			return telegramJSONResponse(http.StatusOK, map[string]any{"ok": true, "result": true}), nil
		default:
			t.Fatalf("unexpected Telegram path %s", request.URL.Path)
			return nil, nil
		}
	})
	client := newClientForTest("secret", "https://telegram.test", &http.Client{Transport: transport})
	audio, err := client.DownloadVoice(context.Background(), "voice-id", 1<<20)
	if err != nil || string(audio) != "OggSvoice" {
		t.Fatalf("DownloadVoice() = %q, %v", audio, err)
	}
	if err := client.SendMessage(context.Background(), 42, "готово"); err != nil || sentText != "готово" {
		t.Fatalf("SendMessage() text=%q err=%v", sentText, err)
	}
}

func TestClientRejectsUnsafeFilePath(t *testing.T) {
	transport := telegramRoundTripFunc(func(_ *http.Request) (*http.Response, error) {
		return telegramJSONResponse(http.StatusOK, map[string]any{
			"ok": true, "result": map[string]any{"file_path": "../secret", "file_size": 9},
		}), nil
	})
	client := newClientForTest("secret", "https://telegram.test", &http.Client{Transport: transport})
	if _, err := client.DownloadVoice(context.Background(), "voice-id", 1<<20); err != ErrInvalidVoice {
		t.Fatalf("error=%v", err)
	}
}

type telegramRoundTripFunc func(*http.Request) (*http.Response, error)

func (function telegramRoundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return function(request)
}

func telegramJSONResponse(status int, value any) *http.Response {
	encoded, _ := json.Marshal(value)
	return &http.Response{
		StatusCode: status,
		Body:       io.NopCloser(strings.NewReader(string(encoded))),
		Header:     make(http.Header),
	}
}
