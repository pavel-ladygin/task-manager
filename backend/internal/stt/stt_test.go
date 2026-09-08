package stt

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestGroqMultipartRequest(t *testing.T) {
	httpClient := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.Header.Get("Authorization") != "Bearer secret" {
			t.Fatal("missing Groq authorization")
		}
		if err := request.ParseMultipartForm(2 << 20); err != nil {
			t.Fatal(err)
		}
		if request.FormValue("model") != "whisper-large-v3" || request.FormValue("language") != "ru" {
			t.Fatalf("unexpected form: %+v", request.Form)
		}
		file, _, err := request.FormFile("file")
		if err != nil {
			t.Fatal(err)
		}
		defer file.Close()
		body, _ := io.ReadAll(file)
		if string(body) != "OggSvoice" {
			t.Fatalf("unexpected audio %q", body)
		}
		return jsonResponse(http.StatusOK, map[string]string{"text": "позвонить завтра в 15:00"}), nil
	})}

	client := &Groq{APIKey: "secret", Endpoint: "https://groq.test/transcribe", HTTPClient: httpClient}
	text, err := client.Transcribe(context.Background(), []byte("OggSvoice"))
	if err != nil || text != "позвонить завтра в 15:00" {
		t.Fatalf("Transcribe() = %q, %v", text, err)
	}
}

func TestYandexRequest(t *testing.T) {
	httpClient := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.Header.Get("Authorization") != "Api-Key secret" || request.Header.Get("x-data-logging-enabled") != "false" {
			t.Fatal("unexpected Yandex headers")
		}
		query := request.URL.Query()
		if query.Get("folderId") != "folder" || query.Get("format") != "oggopus" || query.Get("lang") != "ru-RU" {
			t.Fatalf("unexpected query: %v", query)
		}
		return jsonResponse(http.StatusOK, map[string]string{"result": "купить молоко"}), nil
	})}

	client := &Yandex{APIKey: "secret", FolderID: "folder", Endpoint: "https://yandex.test/transcribe", HTTPClient: httpClient}
	text, err := client.Transcribe(context.Background(), []byte("OggSvoice"))
	if err != nil || text != "купить молоко" {
		t.Fatalf("Transcribe() = %q, %v", text, err)
	}
}

func TestChainRetriesTemporaryErrorThenUsesFallback(t *testing.T) {
	primary := &stubTranscriber{errors: []error{
		&ProviderError{Provider: "primary", Temporary: true, RetryAfter: 5 * time.Second},
		&ProviderError{Provider: "primary", Temporary: true},
	}}
	fallback := &stubTranscriber{text: "готово"}
	var delay time.Duration
	chain := Chain{
		Primary: primary, Fallback: fallback,
		Sleep: func(_ context.Context, duration time.Duration) error { delay = duration; return nil },
	}
	text, err := chain.Transcribe(context.Background(), []byte("voice"))
	if err != nil || text != "готово" {
		t.Fatalf("Transcribe() = %q, %v", text, err)
	}
	if delay != 2*time.Second || primary.calls != 2 || fallback.calls != 1 {
		t.Fatalf("unexpected calls: delay=%v primary=%d fallback=%d", delay, primary.calls, fallback.calls)
	}
}

func TestGroqClassifiesRateLimitForRetry(t *testing.T) {
	httpClient := &http.Client{Transport: roundTripFunc(func(_ *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusTooManyRequests,
			Body:       io.NopCloser(strings.NewReader(`{"error":"limited"}`)),
			Header:     http.Header{"Retry-After": []string{"5"}},
		}, nil
	})}
	client := &Groq{APIKey: "secret", Endpoint: "https://groq.test/transcribe", HTTPClient: httpClient}
	_, err := client.Transcribe(context.Background(), []byte("OggSvoice"))
	var providerError *ProviderError
	if !errors.As(err, &providerError) || !providerError.Temporary || providerError.RetryAfter != 5*time.Second {
		t.Fatalf("unexpected error: %#v", err)
	}
}

func TestYandexClassifiesServerFailureAsTemporary(t *testing.T) {
	httpClient := &http.Client{Transport: roundTripFunc(func(_ *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusBadGateway,
			Body:       io.NopCloser(strings.NewReader(`{"error":"unavailable"}`)),
			Header:     make(http.Header),
		}, nil
	})}
	client := &Yandex{APIKey: "secret", FolderID: "folder", Endpoint: "https://yandex.test/transcribe", HTTPClient: httpClient}
	_, err := client.Transcribe(context.Background(), []byte("OggSvoice"))
	var providerError *ProviderError
	if !errors.As(err, &providerError) || !providerError.Temporary || providerError.StatusCode != http.StatusBadGateway {
		t.Fatalf("unexpected error: %#v", err)
	}
}

type stubTranscriber struct {
	text   string
	errors []error
	calls  int
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (function roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return function(request)
}

func jsonResponse(status int, value any) *http.Response {
	var builder strings.Builder
	_ = json.NewEncoder(&builder).Encode(value)
	return &http.Response{
		StatusCode: status,
		Header:     make(http.Header),
		Body:       io.NopCloser(strings.NewReader(builder.String())),
	}
}

func (stub *stubTranscriber) Transcribe(_ context.Context, _ []byte) (string, error) {
	index := stub.calls
	stub.calls++
	if index < len(stub.errors) {
		return "", stub.errors[index]
	}
	return stub.text, nil
}
