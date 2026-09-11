package telegrambot

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"strings"
	"testing"
	"time"

	"planner-sync/internal/store"
)

func TestFormatMorningDigestFiltersSortsAndIncludesProject(t *testing.T) {
	loc := time.FixedZone("MSK", 3*60*60)
	day := time.Date(2026, 9, 8, 0, 0, 0, 0, loc)
	old := day.Add(-time.Hour).Format(time.RFC3339Nano)
	noon := day.Add(12 * time.Hour).Format(time.RFC3339Nano)
	late := day.Add(18 * time.Hour).Format(time.RFC3339Nano)
	projectID := "p1"
	tasks := []notificationTask{
		{ID: "done", Title: "done", Status: "done", Scheduled: &noon},
		{ID: "none", Title: "none", Status: "planned"},
		{ID: "late", Title: "later", Status: "planned", Scheduled: &late, Priority: "low"},
		{ID: "old", Title: "overdue", Status: "planned", Due: &old, Priority: "urgent"},
		{ID: "noon", Title: "meeting", Status: "planned", Scheduled: &noon, Priority: "high", ProjectID: &projectID},
	}
	got := formatMorningDigest(tasks, map[string]notificationProject{"p1": {ID: "p1", Title: "Work"}}, day, loc)
	for _, want := range []string{"Задач: 3", "Просрочено", "meeting", "Work", "12:00", "18:00"} {
		if !strings.Contains(got, want) {
			t.Errorf("digest missing %q: %s", want, got)
		}
	}
	if strings.Contains(got, "done") || strings.Contains(got, "none") {
		t.Errorf("inactive/no-date tasks included: %s", got)
	}
	if strings.Index(got, "overdue") > strings.Index(got, "meeting") {
		t.Errorf("overdue task should sort first: %s", got)
	}
}

func TestFormatMorningDigestEmptyAndTruncated(t *testing.T) {
	loc := time.FixedZone("MSK", 3*60*60)
	day := time.Date(2026, 9, 8, 0, 0, 0, 0, loc)
	if got := formatMorningDigest(nil, nil, day, loc); !strings.Contains(got, "Сегодня задач нет") {
		t.Fatal(got)
	}
	long := strings.Repeat("x", 5000)
	got := formatMorningDigest([]notificationTask{{ID: "1", Title: long, Status: "planned", Due: ptr(day.Add(10 * time.Hour).Format(time.RFC3339Nano))}}, nil, day, loc)
	if len([]rune(got)) > maximumTelegramText {
		t.Fatalf("digest exceeds Telegram limit: %d", len([]rune(got)))
	}
}

func TestNotifierScanMorningReminderBoundaryAndNoCatchup(t *testing.T) {
	loc := time.FixedZone("MSK", 3*60*60)
	day := time.Date(2026, 9, 8, 0, 0, 0, 0, loc)
	scheduled := day.Add(10 * time.Hour).Format(time.RFC3339Nano)
	tasks := []notificationTask{{ID: "t1", Title: "call", Status: "planned", Scheduled: &scheduled, UpdatedAt: day.Add(-time.Hour).Format(time.RFC3339Nano)}}
	f := &fakeNotifierStore{heads: headsFor(tasks)}
	n := NewNotifier(f, &fakeSender{}, "bot", 7, loc, log.New(testWriter{t}, "", 0))
	ctx := context.Background()
	if err := n.Scan(ctx, day.Add(6*time.Hour+59*time.Minute), day.Add(7*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if len(f.enqueued) != 1 || f.enqueued[0].Kind != notificationMorning {
		t.Fatalf("morning events: %+v", f.enqueued)
	}
	// The exact trigger is 09:45; a scan ending at the trigger enqueues it.
	if err := n.Scan(ctx, day.Add(9*time.Hour+44*time.Minute), day.Add(9*time.Hour+45*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if len(f.enqueued) != 2 || f.enqueued[1].Kind != notificationReminder {
		t.Fatalf("reminder events: %+v", f.enqueued)
	}
	// An interval entirely after the trigger must not backfill an event.
	f2 := &fakeNotifierStore{heads: headsFor(tasks)}
	n2 := NewNotifier(f2, &fakeSender{}, "bot", 7, loc, nil)
	if err := n2.Scan(ctx, day.Add(9*time.Hour+46*time.Minute), day.Add(9*time.Hour+47*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if len(f2.enqueued) != 0 {
		t.Fatalf("caught up missed reminder: %+v", f2.enqueued)
	}
	// Server receipt after the trigger suppresses an offline change even when
	// the client-provided updatedAt is older than the trigger.
	f3 := &fakeNotifierStore{heads: headsFor(tasks)}
	f3.heads[0].ServerUpdatedAt = day.Add(9*time.Hour + 45*time.Minute + time.Second).UTC().Format(time.RFC3339Nano)
	n3 := NewNotifier(f3, &fakeSender{}, "bot", 7, loc, nil)
	if err := n3.Scan(ctx, day.Add(9*time.Hour+44*time.Minute), day.Add(9*time.Hour+45*time.Minute+time.Second)); err != nil {
		t.Fatal(err)
	}
	if len(f3.enqueued) != 0 {
		t.Fatalf("backfilled a task received after its trigger: %+v", f3.enqueued)
	}
}

func TestNotifierInitialBoundaryIncludesExactTriggers(t *testing.T) {
	loc := time.FixedZone("MSK", 3*60*60)
	day := time.Date(2026, 9, 8, 0, 0, 0, 0, loc)
	scheduled := day.Add(7*time.Hour + reminderLeadTime).Format(time.RFC3339Nano)
	tasks := []notificationTask{{
		ID: "t1", Title: "start boundary", Status: "planned", Scheduled: &scheduled,
		UpdatedAt: day.Add(6 * time.Hour).Format(time.RFC3339Nano),
	}}
	f := &fakeNotifierStore{heads: headsFor(tasks)}
	n := NewNotifier(f, &fakeSender{}, "bot", 7, loc, nil)
	start := day.Add(7 * time.Hour)
	if err := n.Scan(context.Background(), start.Add(-time.Nanosecond), start); err != nil {
		t.Fatal(err)
	}
	if len(f.enqueued) != 2 || f.enqueued[0].Kind != notificationMorning || f.enqueued[1].Kind != notificationReminder {
		t.Fatalf("exact startup boundary events: %+v", f.enqueued)
	}
}

func TestNotifierProcessRetriesAndRevalidatesReminder(t *testing.T) {
	loc := time.FixedZone("MSK", 3*60*60)
	now := time.Date(2026, 9, 8, 9, 45, 0, 0, loc)
	taskID := "t1"
	scheduled := now.Add(15 * time.Minute).Format(time.RFC3339Nano)
	n := store.TelegramNotification{BotID: "bot", EventKey: "reminder:t1:x", ChatID: 7, Kind: notificationReminder, TaskID: taskID, EventTime: now.Add(15 * time.Minute), PayloadJSON: notificationPayload("⏰ Через 15 минут")}
	f := &fakeNotifierStore{heads: headsFor([]notificationTask{{ID: taskID, Title: "call", Status: "planned", Scheduled: &scheduled}}), queue: []*store.TelegramNotification{&n}}
	s := &fakeSender{err: errors.New("temporary")}
	notifier := NewNotifier(f, s, "bot", 7, loc, nil)
	notifier.now = func() time.Time { return now }
	worked, err := notifier.ProcessNext(context.Background())
	if err != nil || !worked || len(s.messages) != 1 || f.retries != 1 {
		t.Fatalf("retry path worked=%v err=%v messages=%v retries=%d", worked, err, s.messages, f.retries)
	}
	// A changed schedule invalidates the queued reminder and suppresses delivery.
	changed := now.Add(30 * time.Minute).Format(time.RFC3339Nano)
	f.queue = []*store.TelegramNotification{{BotID: "bot", EventKey: "reminder:t1:y", ChatID: 7, Kind: notificationReminder, TaskID: taskID, EventTime: now.Add(15 * time.Minute), PayloadJSON: notificationPayload("stale")}}
	f.heads = headsFor([]notificationTask{{ID: taskID, Title: "call", Status: "planned", Scheduled: &changed}})
	s.err = nil
	worked, err = notifier.ProcessNext(context.Background())
	if err != nil || !worked || len(s.messages) != 1 || f.finished != 1 {
		t.Fatalf("revalidation path worked=%v err=%v messages=%v finished=%d", worked, err, s.messages, f.finished)
	}
}

func TestNotifierProcessRefreshesMorningDigestFromCurrentHeads(t *testing.T) {
	loc := time.FixedZone("MSK", 3*60*60)
	day := time.Date(2026, 9, 8, 0, 0, 0, 0, loc)
	noon := day.Add(12 * time.Hour).Format(time.RFC3339Nano)
	task := notificationTask{ID: "t1", Title: "Завершить задачу", Status: "planned", Scheduled: &noon}
	n := store.TelegramNotification{
		BotID: "bot", EventKey: "morning:2026-09-08", ChatID: 7,
		Kind: notificationMorning, EventTime: day.Add(7 * time.Hour),
		// This is the stale snapshot captured at enqueue time.
		PayloadJSON: notificationPayload(formatMorningDigest([]notificationTask{task}, nil, day, loc)),
	}
	f := &fakeNotifierStore{heads: headsFor([]notificationTask{{ID: "t1", Title: task.Title, Status: "done", Scheduled: &noon}}), queue: []*store.TelegramNotification{&n}}
	s := &fakeSender{}
	notifier := NewNotifier(f, s, "bot", 7, loc, nil)
	notifier.now = func() time.Time { return day.Add(8 * time.Hour) }
	worked, err := notifier.ProcessNext(context.Background())
	if err != nil || !worked || len(s.messages) != 1 {
		t.Fatalf("morning delivery worked=%v err=%v messages=%v", worked, err, s.messages)
	}
	if strings.Contains(s.messages[0], task.Title) || !strings.Contains(s.messages[0], "Сегодня задач нет") {
		t.Fatalf("stale completed task was delivered: %s", s.messages[0])
	}
}

func ptr(s string) *string { return &s }
func headsFor(tasks []notificationTask) []store.Change {
	out := make([]store.Change, 0, len(tasks))
	for _, task := range tasks {
		b, _ := json.Marshal(task)
		out = append(out, store.Change{EntityType: "task", EntityID: task.ID, Operation: "upsert", PayloadJSON: string(b)})
	}
	return out
}

type testWriter struct{ t *testing.T }

func (w testWriter) Write(p []byte) (int, error) { w.t.Helper(); return len(p), nil }

type fakeSender struct {
	messages []string
	err      error
}

func (s *fakeSender) SendMessage(_ context.Context, _ int64, text string) error {
	s.messages = append(s.messages, text)
	return s.err
}

type fakeNotifierStore struct {
	heads             []store.Change
	enqueued          []store.TelegramNotification
	queue             []*store.TelegramNotification
	retries, finished int
}

func (f *fakeNotifierStore) NotificationHeads(context.Context) ([]store.Change, error) {
	return f.heads, nil
}
func (f *fakeNotifierStore) EnqueueTelegramNotification(_ context.Context, n store.TelegramNotification, _ time.Time) (bool, error) {
	for _, x := range f.enqueued {
		if x.EventKey == n.EventKey {
			return false, nil
		}
	}
	f.enqueued = append(f.enqueued, n)
	return true, nil
}
func (f *fakeNotifierStore) ClaimTelegramNotification(context.Context, string, time.Time, time.Duration) (*store.TelegramNotification, error) {
	if len(f.queue) == 0 {
		return nil, nil
	}
	n := f.queue[0]
	f.queue = f.queue[1:]
	n.AttemptCount++
	return n, nil
}
func (f *fakeNotifierStore) RetryTelegramNotification(context.Context, string, string, int, time.Time, string, time.Time) error {
	f.retries++
	return nil
}
func (f *fakeNotifierStore) FinishTelegramNotification(context.Context, string, string, int, string, string, time.Time) error {
	f.finished++
	return nil
}
