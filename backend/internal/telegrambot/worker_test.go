package telegrambot

import (
	"context"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"planner-sync/internal/store"
	"planner-sync/internal/taskparser"
)

func TestWorkerCreatesExactlyOneTaskAndConfirms(t *testing.T) {
	syncStore, err := store.Open(filepath.Join(t.TempDir(), "planner.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer syncStore.Close()
	if _, _, err := syncStore.Initialize(nil); err != nil {
		t.Fatal(err)
	}
	location, err := time.LoadLocation("Europe/Moscow")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 9, 7, 14, 30, 0, 0, time.UTC)
	update := store.TelegramUpdate{
		BotID: "123", UpdateID: 7, ChatID: 42, MessageDate: now.Unix(), Kind: "text",
		PayloadJSON: `{"text":"сходить посрать в 18:00 сегодня"}`,
		TaskID:      "00000000-0000-4000-8000-000000000007",
	}
	if inserted, err := syncStore.EnqueueTelegramUpdate(context.Background(), update, now); err != nil || !inserted {
		t.Fatalf("enqueue inserted=%v err=%v", inserted, err)
	}
	if inserted, err := syncStore.EnqueueTelegramUpdate(context.Background(), update, now); err != nil || inserted {
		t.Fatalf("duplicate inserted=%v err=%v", inserted, err)
	}
	api := &fakeAPI{}
	worker := NewWorker(syncStore, api, nil, NewTaskCreator(syncStore), "123", location, nil)
	worker.now = func() time.Time { return now }

	if worked, err := worker.ProcessNext(context.Background()); err != nil || !worked {
		t.Fatalf("process worked=%v err=%v", worked, err)
	}
	queued, err := syncStore.TelegramUpdate(context.Background(), "123", 7)
	if err != nil || queued.Status != store.TelegramCommitted || queued.ServerRevision == nil {
		t.Fatalf("unexpected committed job: %+v err=%v", queued, err)
	}
	if worked, err := worker.ProcessNext(context.Background()); err != nil || !worked {
		t.Fatalf("confirm worked=%v err=%v", worked, err)
	}
	finished, err := syncStore.TelegramUpdate(context.Background(), "123", 7)
	if err != nil || finished.Status != store.TelegramDone || finished.PayloadJSON != "" {
		t.Fatalf("unexpected finished job: %+v err=%v", finished, err)
	}
	if len(api.messages) != 1 || !strings.Contains(api.messages[0], "Сходить посрать") || !strings.Contains(api.messages[0], "18:00") {
		t.Fatalf("unexpected confirmations: %v", api.messages)
	}

	changes, _, _, err := syncStore.Changes(0, 20)
	if err != nil || len(changes) != 1 {
		t.Fatalf("changes=%+v err=%v", changes, err)
	}
	var payload taskPayload
	if err := json.Unmarshal([]byte(changes[0].PayloadJSON), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.ID != update.TaskID || payload.Title != "Сходить посрать" || payload.Status != "planned" || payload.Scheduled == nil || !strings.Contains(*payload.Scheduled, "18:00:00+03:00") {
		t.Fatalf("unexpected task payload: %+v", payload)
	}

	creator := NewTaskCreator(syncStore)
	if _, err := creator.Create(update, mustDraft(t, "сходить посрать в 18:00 сегодня", now, location), location); err != nil {
		t.Fatalf("idempotent create failed: %v", err)
	}
	changes, _, _, err = syncStore.Changes(0, 20)
	if err != nil || len(changes) != 1 {
		t.Fatalf("duplicate create appended a change: changes=%d err=%v", len(changes), err)
	}
}

func TestWorkerTranscribesVoice(t *testing.T) {
	syncStore, err := store.Open(filepath.Join(t.TempDir(), "planner.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer syncStore.Close()
	if _, _, err := syncStore.Initialize(nil); err != nil {
		t.Fatal(err)
	}
	location, _ := time.LoadLocation("Europe/Moscow")
	now := time.Date(2026, 9, 7, 14, 30, 0, 0, time.UTC)
	update := store.TelegramUpdate{
		BotID: "123", UpdateID: 8, ChatID: 42, MessageDate: now.Unix(), Kind: "voice",
		PayloadJSON: `{"fileID":"voice-id","fileSize":100,"duration":5}`,
		TaskID:      "00000000-0000-4000-8000-000000000008",
	}
	if _, err := syncStore.EnqueueTelegramUpdate(context.Background(), update, now); err != nil {
		t.Fatal(err)
	}
	api := &fakeAPI{audio: []byte("OggSvoice")}
	transcriber := &fakeTranscriber{text: "позвонить врачу завтра в 15:00"}
	worker := NewWorker(syncStore, api, transcriber, NewTaskCreator(syncStore), "123", location, nil)
	worker.now = func() time.Time { return now }
	if _, err := worker.ProcessNext(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := worker.ProcessNext(context.Background()); err != nil {
		t.Fatal(err)
	}
	if transcriber.calls != 1 || api.downloads != 1 || len(api.messages) != 1 || !strings.Contains(api.messages[0], "Распознано") {
		t.Fatalf("voice path not exercised: transcriber=%d downloads=%d messages=%v", transcriber.calls, api.downloads, api.messages)
	}
}

type fakeAPI struct {
	audio     []byte
	messages  []string
	downloads int
	sendError error
}

func (api *fakeAPI) DownloadVoice(_ context.Context, _ string, _ int64) ([]byte, error) {
	api.downloads++
	return api.audio, nil
}

func (api *fakeAPI) SendMessage(_ context.Context, _ int64, text string) error {
	api.messages = append(api.messages, text)
	return api.sendError
}

type fakeTranscriber struct {
	text  string
	calls int
}

func (transcriber *fakeTranscriber) Transcribe(_ context.Context, _ []byte) (string, error) {
	transcriber.calls++
	return transcriber.text, nil
}

func mustDraft(t *testing.T, input string, now time.Time, location *time.Location) taskparser.Draft {
	t.Helper()
	draft, err := taskparser.Parse(input, now, location)
	if err != nil {
		t.Fatal(err)
	}
	return draft
}
