package store

import (
	"context"
	"path/filepath"
	"testing"
	"time"
)

func TestTelegramNotificationQueueIsIdempotentAndLeased(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "planner.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	now := time.Date(2026, 9, 8, 6, 45, 0, 0, time.UTC)
	n := TelegramNotification{BotID: "bot", EventKey: "reminder:task-1:2026-09-08T07:00:00Z", ChatID: 9, Kind: "reminder", TaskID: "task-1", EventTime: now.Add(15 * time.Minute), PayloadJSON: `{"text":"test"}`}
	inserted, err := s.EnqueueTelegramNotification(ctx, n, now)
	if err != nil || !inserted {
		t.Fatalf("enqueue: inserted=%v err=%v", inserted, err)
	}
	inserted, err = s.EnqueueTelegramNotification(ctx, n, now)
	if err != nil || inserted {
		t.Fatalf("duplicate enqueue: inserted=%v err=%v", inserted, err)
	}
	otherBot := n
	otherBot.BotID = "other-bot"
	if inserted, err = s.EnqueueTelegramNotification(ctx, otherBot, now); err != nil || !inserted {
		t.Fatalf("same event key for another bot: inserted=%v err=%v", inserted, err)
	}
	claimed, err := s.ClaimTelegramNotification(ctx, "bot", now, time.Minute)
	if err != nil || claimed == nil || claimed.Status != "processing" || claimed.AttemptCount != 1 {
		t.Fatalf("claim: %+v (%v)", claimed, err)
	}
	if again, err := s.ClaimTelegramNotification(ctx, "bot", now.Add(30*time.Second), time.Minute); err != nil || again != nil {
		t.Fatalf("active lease reclaimed: %+v (%v)", again, err)
	}
	recovered, err := s.ClaimTelegramNotification(ctx, "bot", now.Add(61*time.Second), time.Minute)
	if err != nil || recovered == nil || recovered.AttemptCount != 2 {
		t.Fatalf("lease recovery: %+v (%v)", recovered, err)
	}
	if err := s.FinishTelegramNotification(ctx, "bot", n.EventKey, claimed.AttemptCount, "done", "", now.Add(61*time.Second)); err == nil {
		t.Fatal("stale claimant unexpectedly finished a reclaimed notification")
	}
	if err := s.RetryTelegramNotification(ctx, "bot", n.EventKey, recovered.AttemptCount, now.Add(2*time.Minute), "temporary", now.Add(61*time.Second)); err != nil {
		t.Fatal(err)
	}
	if got, err := s.ClaimTelegramNotification(ctx, "bot", now.Add(90*time.Second), time.Minute); err != nil || got != nil {
		t.Fatalf("retry claimed too early: %+v (%v)", got, err)
	}
	finalClaim, err := s.ClaimTelegramNotification(ctx, "bot", now.Add(2*time.Minute), time.Minute)
	if err != nil || finalClaim == nil || finalClaim.AttemptCount != 3 {
		t.Fatalf("final claim: %+v (%v)", finalClaim, err)
	}
	if err := s.FinishTelegramNotification(ctx, "bot", n.EventKey, finalClaim.AttemptCount, "done", "", now.Add(2*time.Minute)); err != nil {
		t.Fatal(err)
	}
	got, err := s.TelegramNotification(ctx, "bot", n.EventKey)
	if err != nil || got.Status != "done" || got.LastError != "" {
		t.Fatalf("finished notification: %+v (%v)", got, err)
	}
}

func TestNotificationHeadsAndCurrentHead(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "planner.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	created := time.Date(2026, 9, 8, 7, 0, 0, 0, time.UTC).Format(time.RFC3339Nano)
	if _, _, err := s.Initialize([]Mutation{{MutationID: "m1", EntityType: "task", EntityID: "task-1", Operation: "upsert", PayloadJSON: `{"title":"Today"}`, BaseRevision: 0, CreatedAt: created, SourceDeviceID: "test"}}); err != nil {
		t.Fatal(err)
	}
	heads, err := s.NotificationHeads(context.Background())
	if err != nil || len(heads) != 1 || heads[0].EntityID != "task-1" {
		t.Fatalf("heads: %+v (%v)", heads, err)
	}
	head, err := s.CurrentHead(context.Background(), "task", "task-1")
	if err != nil || head.PayloadJSON != `{"title":"Today"}` {
		t.Fatalf("current head: %+v (%v)", head, err)
	}
}
