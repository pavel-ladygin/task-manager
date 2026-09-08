package store

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

func TestMigrationFromV1CreatesBackupAndIsRepeatable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "planner.db")
	db, err := sql.Open("sqlite3", path)
	if err != nil {
		t.Fatal(err)
	}
	statements := []string{
		`CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)`,
		`INSERT INTO schema_migrations(version, applied_at) VALUES(1, '2026-07-22T00:00:00.000Z')`,
		`CREATE TABLE sync_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
		`INSERT INTO sync_meta(key, value) VALUES('revision', '0')`,
		`CREATE TABLE sync_items (entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, payload_json TEXT NOT NULL, client_updated_at TEXT NOT NULL, server_updated_at TEXT NOT NULL, deleted_at TEXT, version INTEGER NOT NULL, source_device_id TEXT NOT NULL, server_revision INTEGER NOT NULL, PRIMARY KEY(entity_type, entity_id))`,
		`INSERT INTO sync_items VALUES('task', 'task-1', '{}', '2026-07-22T00:00:00.000Z', '2026-07-22T00:00:00.000Z', NULL, 1, 'mac', 1)`,
	}
	for _, statement := range statements {
		if _, err := db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	first, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	second, err := Open(path)
	if err != nil {
		t.Fatalf("repeated migration must be idempotent: %v", err)
	}
	defer second.Close()

	var version int
	if err := second.db.QueryRow(`SELECT MAX(version) FROM schema_migrations`).Scan(&version); err != nil || version != latestSchemaVersion {
		t.Fatalf("unexpected schema version %d: %v", version, err)
	}
	backups, err := filepath.Glob(filepath.Join(filepath.Dir(path), "migration-backups", "*.bak"))
	if err != nil || len(backups) != 1 {
		t.Fatalf("expected one pre-migration backup, got %v (%v)", backups, err)
	}
}

func TestMigrationFromV3AddsTelegramQueueAndKeepsSyncData(t *testing.T) {
	path := filepath.Join(t.TempDir(), "planner.db")
	db, err := sql.Open("sqlite3", path)
	if err != nil {
		t.Fatal(err)
	}
	statements := []string{
		`CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)`,
		`INSERT INTO schema_migrations(version, applied_at) VALUES(1, '2026-09-07T00:00:00Z'), (2, '2026-09-07T00:00:00Z'), (3, '2026-09-07T00:00:00Z')`,
		`CREATE TABLE sync_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
		`INSERT INTO sync_meta(key, value) VALUES('revision', '1'), ('initialized', '1')`,
		`CREATE TABLE sync_items (entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, payload_json TEXT NOT NULL, client_updated_at TEXT NOT NULL, server_updated_at TEXT NOT NULL, deleted_at TEXT, version INTEGER NOT NULL, source_device_id TEXT NOT NULL, server_revision INTEGER NOT NULL, PRIMARY KEY(entity_type, entity_id))`,
		`CREATE TABLE entity_heads (entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, operation TEXT NOT NULL, payload_json TEXT NOT NULL, revision INTEGER NOT NULL, source_device_id TEXT NOT NULL, server_updated_at TEXT NOT NULL, PRIMARY KEY(entity_type, entity_id))`,
		`CREATE TABLE change_log (revision INTEGER PRIMARY KEY, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, operation TEXT NOT NULL, payload_json TEXT NOT NULL, source_device_id TEXT NOT NULL, server_updated_at TEXT NOT NULL)`,
		`INSERT INTO change_log VALUES(1, 'task', 'kept-task', 'upsert', '{}', 'mac', '2026-09-07T00:00:00Z')`,
		`CREATE TABLE applied_mutations (mutation_id TEXT PRIMARY KEY, server_revision INTEGER NOT NULL, applied_at TEXT NOT NULL)`,
	}
	for _, statement := range statements {
		if _, err := db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	opened, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer opened.Close()
	var count int
	if err := opened.db.QueryRow(`SELECT COUNT(*) FROM change_log WHERE entity_id = 'kept-task'`).Scan(&count); err != nil || count != 1 {
		t.Fatalf("sync data was not preserved: count=%d err=%v", count, err)
	}
	if err := opened.db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='telegram_updates'`).Scan(&count); err != nil || count != 1 {
		t.Fatalf("telegram queue was not created: count=%d err=%v", count, err)
	}
	if err := opened.db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='telegram_notifications'`).Scan(&count); err != nil || count != 1 {
		t.Fatalf("telegram notification queue was not created: count=%d err=%v", count, err)
	}
}

func TestTelegramQueueDeduplicatesAndRecoversExpiredLease(t *testing.T) {
	opened, err := Open(filepath.Join(t.TempDir(), "planner.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer opened.Close()
	ctx := context.Background()
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	update := TelegramUpdate{
		BotID: "123", UpdateID: 42, ChatID: 7, MessageDate: now.Unix(), Kind: "text",
		PayloadJSON: `{"text":"задача"}`, TaskID: "00000000-0000-4000-8000-000000000042",
	}
	inserted, err := opened.EnqueueTelegramUpdate(ctx, update, now)
	if err != nil || !inserted {
		t.Fatalf("first enqueue: inserted=%v err=%v", inserted, err)
	}
	inserted, err = opened.EnqueueTelegramUpdate(ctx, update, now)
	if err != nil || inserted {
		t.Fatalf("duplicate enqueue: inserted=%v err=%v", inserted, err)
	}

	claimed, err := opened.ClaimTelegramUpdate(ctx, "123", now.Add(500*time.Millisecond), time.Minute)
	if err != nil || claimed == nil || claimed.Status != TelegramProcessing || claimed.AttemptCount != 1 {
		t.Fatalf("first claim: update=%+v err=%v", claimed, err)
	}
	if second, err := opened.ClaimTelegramUpdate(ctx, "123", now.Add(30*time.Second), time.Minute); err != nil || second != nil {
		t.Fatalf("active lease should not be claimed: update=%+v err=%v", second, err)
	}
	recovered, err := opened.ClaimTelegramUpdate(ctx, "123", now.Add(61*time.Second), time.Minute)
	if err != nil || recovered == nil || recovered.AttemptCount != 2 {
		t.Fatalf("expired lease was not recovered: update=%+v err=%v", recovered, err)
	}
}

func TestTelegramQueueCommittedPayloadIsClearedOnDone(t *testing.T) {
	opened, err := Open(filepath.Join(t.TempDir(), "planner.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer opened.Close()
	ctx := context.Background()
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	update := TelegramUpdate{
		BotID: "123", UpdateID: 43, ChatID: 7, MessageDate: now.Unix(), Kind: "voice",
		PayloadJSON: `{"fileID":"private"}`, TaskID: "00000000-0000-4000-8000-000000000043",
	}
	if _, err := opened.EnqueueTelegramUpdate(ctx, update, now); err != nil {
		t.Fatal(err)
	}
	if _, err := opened.ClaimTelegramUpdate(ctx, "123", now, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := opened.MarkTelegramCommitted(ctx, "123", 43, 9, "private confirmation", now); err != nil {
		t.Fatal(err)
	}
	if err := opened.FinishTelegramUpdate(ctx, "123", 43, TelegramDone, "", now); err != nil {
		t.Fatal(err)
	}
	stored, err := opened.TelegramUpdate(ctx, "123", 43)
	if err != nil {
		t.Fatal(err)
	}
	if stored.Status != TelegramDone || stored.PayloadJSON != "" || stored.ConfirmationText != "" || stored.ServerRevision == nil || *stored.ServerRevision != 9 {
		t.Fatalf("unexpected terminal update: %+v", stored)
	}
}

func TestUnknownNewerSchemaIsRejected(t *testing.T) {
	path := filepath.Join(t.TempDir(), "planner.db")
	db, err := sql.Open("sqlite3", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
		INSERT INTO schema_migrations(version, applied_at) VALUES(999, '2026-07-22T00:00:00.000Z')`)
	if err != nil {
		t.Fatal(err)
	}
	_ = db.Close()

	if opened, err := Open(path); err == nil {
		_ = opened.Close()
		t.Fatal("expected newer schema to be rejected")
	}
}

func TestTransactionRollsBackOnFailure(t *testing.T) {
	path := filepath.Join(t.TempDir(), "planner.db")
	opened, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer opened.Close()

	want := errors.New("force rollback")
	err = opened.withTx(func(tx *sql.Tx) error {
		if _, err := tx.Exec(`INSERT INTO sync_meta(key, value) VALUES('rollback-test', '1')`); err != nil {
			return err
		}
		return want
	})
	if !errors.Is(err, want) {
		t.Fatalf("unexpected transaction error: %v", err)
	}
	var count int
	if err := opened.db.QueryRow(`SELECT COUNT(*) FROM sync_meta WHERE key = 'rollback-test'`).Scan(&count); err != nil || count != 0 {
		t.Fatalf("transaction was not rolled back: count=%d err=%v", count, err)
	}

	if _, err := os.Stat(path); err != nil {
		t.Fatalf("database must remain intact after rollback: %v", err)
	}
}

func TestExplicitInitializationGate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "planner.db")
	opened, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer opened.Close()

	if empty, err := opened.IsEmpty(); err != nil || !empty {
		t.Fatalf("new store must be empty: empty=%v err=%v", empty, err)
	}
	if _, _, err := opened.ApplyMutations(nil); err == nil {
		t.Fatal("ordinary mutations must be rejected before initialization")
	}
	if _, _, err := opened.Initialize(nil); err != nil {
		t.Fatalf("explicit initialization failed: %v", err)
	}
	if empty, err := opened.IsEmpty(); err != nil || empty {
		t.Fatalf("initialized store must not be empty: empty=%v err=%v", empty, err)
	}
}
