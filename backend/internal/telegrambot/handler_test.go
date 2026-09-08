package telegrambot

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"planner-sync/internal/store"
)

func TestWebhookRequiresSecret(t *testing.T) {
	queue := &fakeUpdateQueue{}
	handler := testHandler(queue)
	request := telegramRequest(t, validTextUpdate(1, 42))
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized || len(queue.updates) != 0 {
		t.Fatalf("unexpected response=%d updates=%d", response.Code, len(queue.updates))
	}
}

func TestWebhookSilentlyIgnoresOtherUsers(t *testing.T) {
	queue := &fakeUpdateQueue{}
	handler := testHandler(queue)
	request := telegramRequest(t, validTextUpdate(1, 99))
	request.Header.Set("X-Telegram-Bot-Api-Secret-Token", "0123456789abcdef")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK || len(queue.updates) != 0 {
		t.Fatalf("unexpected response=%d updates=%d", response.Code, len(queue.updates))
	}
}

func TestWebhookQueuesTextAndNotifies(t *testing.T) {
	queue := &fakeUpdateQueue{inserted: true}
	notified := 0
	handler := testHandler(queue)
	handler.notify = func() { notified++ }
	request := telegramRequest(t, validTextUpdate(7, 42))
	request.Header.Set("X-Telegram-Bot-Api-Secret-Token", "0123456789abcdef")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK || len(queue.updates) != 1 || notified != 1 {
		t.Fatalf("response=%d updates=%d notified=%d", response.Code, len(queue.updates), notified)
	}
	queued := queue.updates[0]
	if queued.BotID != "123" || queued.UpdateID != 7 || queued.Kind != "text" || queued.TaskID != "00000000-0000-4000-8000-000000000007" {
		t.Fatalf("unexpected update: %+v", queued)
	}
	var payload queuedPayload
	if err := json.Unmarshal([]byte(queued.PayloadJSON), &payload); err != nil || payload.Text != "купить молоко завтра в 15:00" {
		t.Fatalf("unexpected payload: %+v err=%v", payload, err)
	}
}

func TestWebhookTurnsOversizedVoiceIntoGuidanceJob(t *testing.T) {
	queue := &fakeUpdateQueue{inserted: true}
	handler := testHandler(queue)
	update := validTextUpdate(8, 42)
	update.Message.Text = ""
	update.Message.Voice = &Voice{FileID: "voice", Duration: 31, FileSize: maximumVoiceBytes}
	request := telegramRequest(t, update)
	request.Header.Set("X-Telegram-Bot-Api-Secret-Token", "0123456789abcdef")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK || len(queue.updates) != 1 || queue.updates[0].Kind != "unsupported" {
		t.Fatalf("unexpected result: response=%d updates=%+v", response.Code, queue.updates)
	}
}

func TestWebhookRejectsMalformedJSON(t *testing.T) {
	queue := &fakeUpdateQueue{}
	handler := testHandler(queue)
	request := httptest.NewRequest(http.MethodPost, "/telegram/webhook", bytes.NewBufferString(`{"update_id":`))
	request.Header.Set("X-Telegram-Bot-Api-Secret-Token", "0123456789abcdef")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("response=%d", response.Code)
	}
}

type fakeUpdateQueue struct {
	updates  []store.TelegramUpdate
	inserted bool
	err      error
}

func (queue *fakeUpdateQueue) EnqueueTelegramUpdate(_ context.Context, update store.TelegramUpdate, _ time.Time) (bool, error) {
	queue.updates = append(queue.updates, update)
	return queue.inserted, queue.err
}

func testHandler(queue updateQueue) *Handler {
	handler := NewHandler(queue, "123", "0123456789abcdef", 42, nil).(*Handler)
	handler.now = func() time.Time { return time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC) }
	handler.newTaskID = func() (string, error) { return "00000000-0000-4000-8000-000000000007", nil }
	return handler
}

func validTextUpdate(updateID int64, userID int64) Update {
	return Update{
		UpdateID: updateID,
		Message: &Message{
			MessageID: 1, Date: 1788771600, Chat: Chat{ID: userID, Type: "private"},
			From: &User{ID: userID}, Text: "купить молоко завтра в 15:00",
		},
	}
}

func telegramRequest(t *testing.T, update Update) *http.Request {
	t.Helper()
	body, err := json.Marshal(update)
	if err != nil {
		t.Fatal(err)
	}
	return httptest.NewRequest(http.MethodPost, "/telegram/webhook", bytes.NewReader(body))
}
