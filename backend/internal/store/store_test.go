package store

import (
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"

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
