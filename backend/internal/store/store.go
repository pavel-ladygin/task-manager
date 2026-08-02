package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

type Store struct {
	db *sql.DB
}

type Item struct {
	EntityType      string
	EntityID        string
	PayloadJSON     string
	ClientUpdatedAt string
	ServerUpdatedAt string
	DeletedAt       *string
	Version         int64
	SourceDeviceID  string
	ServerRevision  int64
}

type Mutation struct {
	MutationID     string
	EntityType     string
	EntityID       string
	Operation      string
	PayloadJSON    string
	BaseRevision   int64
	CreatedAt      string
	SourceDeviceID string
}

type Change struct {
	Revision        int64
	EntityType      string
	EntityID        string
	Operation       string
	PayloadJSON     string
	SourceDeviceID  string
	ServerUpdatedAt string
}

type MutationResult struct {
	MutationID     string
	Status         string
	ServerRevision int64
	Current        *Change
}

const latestSchemaVersion = 3

func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite3", path+"?_busy_timeout=5000&_journal_mode=WAL&_foreign_keys=ON")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)

	store := &Store{db: db}
	if err := store.migrate(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return store, nil
}

func (store *Store) Close() error {
	return store.db.Close()
}

func (store *Store) migrate() error {
	if _, err := store.db.Exec(`CREATE TABLE IF NOT EXISTS schema_migrations (
		version INTEGER PRIMARY KEY,
		applied_at TEXT NOT NULL
	)`); err != nil {
		return err
	}

	var current int
	if err := store.db.QueryRow(`SELECT COALESCE(MAX(version), 0) FROM schema_migrations`).Scan(&current); err != nil {
		return err
	}
	if current > latestSchemaVersion {
		return fmt.Errorf("database schema %d is newer than supported %d", current, latestSchemaVersion)
	}
	if current < latestSchemaVersion {
		if err := store.backupBeforeMigration(current); err != nil {
			return fmt.Errorf("backup before migration: %w", err)
		}
	}

	migrations := map[int][]string{
		1: {
			`CREATE TABLE IF NOT EXISTS sync_meta (
			key TEXT PRIMARY KEY,
			value TEXT NOT NULL
		)`,
			`INSERT OR IGNORE INTO sync_meta (key, value) VALUES ('revision', '0')`,
			`CREATE TABLE IF NOT EXISTS sync_items (
			entity_type TEXT NOT NULL,
			entity_id TEXT NOT NULL,
			payload_json TEXT NOT NULL,
			client_updated_at TEXT NOT NULL,
			server_updated_at TEXT NOT NULL,
			deleted_at TEXT,
			version INTEGER NOT NULL,
			source_device_id TEXT NOT NULL,
			server_revision INTEGER NOT NULL,
			PRIMARY KEY (entity_type, entity_id)
		)`,
			`CREATE INDEX IF NOT EXISTS idx_sync_items_server_revision ON sync_items(server_revision)`,
			`CREATE INDEX IF NOT EXISTS idx_sync_items_type_id ON sync_items(entity_type, entity_id)`,
		},
		2: {
			`CREATE TABLE IF NOT EXISTS entity_heads (
			entity_type TEXT NOT NULL,
			entity_id TEXT NOT NULL,
			operation TEXT NOT NULL CHECK(operation IN ('upsert', 'delete')),
			payload_json TEXT NOT NULL,
			revision INTEGER NOT NULL,
			source_device_id TEXT NOT NULL,
			server_updated_at TEXT NOT NULL,
			PRIMARY KEY(entity_type, entity_id)
		)`,
			`CREATE TABLE IF NOT EXISTS change_log (
			revision INTEGER PRIMARY KEY,
			entity_type TEXT NOT NULL,
			entity_id TEXT NOT NULL,
			operation TEXT NOT NULL CHECK(operation IN ('upsert', 'delete')),
			payload_json TEXT NOT NULL,
			source_device_id TEXT NOT NULL,
			server_updated_at TEXT NOT NULL
		)`,
			`CREATE INDEX IF NOT EXISTS idx_change_log_entity ON change_log(entity_type, entity_id)`,
			`CREATE TABLE IF NOT EXISTS applied_mutations (
			mutation_id TEXT PRIMARY KEY,
			server_revision INTEGER NOT NULL,
			applied_at TEXT NOT NULL
			)`,
		},
		3: {
			`INSERT OR IGNORE INTO sync_meta (key, value)
			SELECT 'initialized',
				CASE WHEN EXISTS (SELECT 1 FROM entity_heads) THEN '1' ELSE '0' END`,
		},
	}

	for version := current + 1; version <= latestSchemaVersion; version++ {
		statements, ok := migrations[version]
		if !ok {
			return fmt.Errorf("missing migration %d", version)
		}
		if err := store.withTx(func(tx *sql.Tx) error {
			for _, statement := range statements {
				if _, err := tx.Exec(statement); err != nil {
					return err
				}
			}
			_, err := tx.Exec(
				`INSERT INTO schema_migrations(version, applied_at) VALUES(?, ?)`,
				version,
				time.Now().UTC().Format(time.RFC3339Nano),
			)
			return err
		}); err != nil {
			return fmt.Errorf("migration %d: %w", version, err)
		}
	}
	return nil
}

func (store *Store) backupBeforeMigration(currentVersion int) error {
	var applicationTableCount int
	if err := store.db.QueryRow(`SELECT COUNT(*) FROM sqlite_master
		WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name <> 'schema_migrations'`).Scan(&applicationTableCount); err != nil {
		return err
	}
	if applicationTableCount == 0 {
		return nil
	}

	var path string
	if err := store.db.QueryRow(`PRAGMA database_list`).Scan(new(int), new(string), &path); err != nil || path == "" {
		return nil
	}
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) || (err == nil && info.Size() == 0) {
		return nil
	}
	if err != nil {
		return err
	}
	if _, err := store.db.Exec(`PRAGMA wal_checkpoint(FULL)`); err != nil {
		return err
	}

	source, err := os.Open(path)
	if err != nil {
		return err
	}
	defer source.Close()
	backupDir := filepath.Join(filepath.Dir(path), "migration-backups")
	if err := os.MkdirAll(backupDir, 0o700); err != nil {
		return err
	}
	name := fmt.Sprintf("%s-v%d-%s.bak", filepath.Base(path), currentVersion, time.Now().UTC().Format("20060102T150405.000000000Z"))
	target, err := os.OpenFile(filepath.Join(backupDir, name), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err = io.Copy(target, source); err != nil {
		_ = target.Close()
		return err
	}
	return target.Close()
}

func (store *Store) Cursor() (int64, error) {
	var cursor int64
	err := store.db.QueryRow(`SELECT CAST(value AS INTEGER) FROM sync_meta WHERE key = 'revision'`).Scan(&cursor)
	return cursor, err
}

func (store *Store) Push(items []Item) (accepted int, ignored int, cursor int64, err error) {
	err = store.withTx(func(tx *sql.Tx) error {
		for _, item := range items {
			if err := validateItem(item); err != nil {
				return err
			}

			shouldApply, err := shouldApply(tx, item)
			if err != nil {
				return err
			}
			if !shouldApply {
				ignored++
				continue
			}

			revision, err := nextRevision(tx)
			if err != nil {
				return err
			}
			item.ServerRevision = revision
			item.ServerUpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)

			if err := upsertItem(tx, item); err != nil {
				return err
			}
			accepted++
		}

		var err error
		cursor, err = cursorTx(tx)
		return err
	})
	return accepted, ignored, cursor, err
}

func (store *Store) Pull(afterCursor int64) ([]Item, int64, error) {
	rows, err := store.db.Query(
		`SELECT entity_type, entity_id, payload_json, client_updated_at, server_updated_at,
			deleted_at, version, source_device_id, server_revision
		FROM sync_items
		WHERE server_revision > ?
		ORDER BY server_revision ASC`,
		afterCursor,
	)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	items := []Item{}
	for rows.Next() {
		var item Item
		var deletedAt sql.NullString
		if err := rows.Scan(
			&item.EntityType,
			&item.EntityID,
			&item.PayloadJSON,
			&item.ClientUpdatedAt,
			&item.ServerUpdatedAt,
			&deletedAt,
			&item.Version,
			&item.SourceDeviceID,
			&item.ServerRevision,
		); err != nil {
			return nil, 0, err
		}
		if deletedAt.Valid {
			item.DeletedAt = &deletedAt.String
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	cursor, err := store.Cursor()
	return items, cursor, err
}

func (store *Store) withTx(fn func(*sql.Tx) error) error {
	tx, err := store.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit()
}

func validateItem(item Item) error {
	if item.EntityType == "" {
		return errors.New("entityType is required")
	}
	if item.EntityID == "" {
		return errors.New("entityID is required")
	}
	if item.ClientUpdatedAt == "" {
		return errors.New("clientUpdatedAt is required")
	}
	if item.SourceDeviceID == "" {
		return errors.New("sourceDeviceID is required")
	}
	if _, err := time.Parse(time.RFC3339Nano, item.ClientUpdatedAt); err != nil {
		return fmt.Errorf("invalid clientUpdatedAt: %w", err)
	}
	if item.DeletedAt != nil {
		if _, err := time.Parse(time.RFC3339Nano, *item.DeletedAt); err != nil {
			return fmt.Errorf("invalid deletedAt: %w", err)
		}
	}
	return nil
}

func shouldApply(tx *sql.Tx, item Item) (bool, error) {
	var existingClientUpdatedAt string
	var existingVersion int64
	err := tx.QueryRow(
		`SELECT client_updated_at, version FROM sync_items WHERE entity_type = ? AND entity_id = ?`,
		item.EntityType,
		item.EntityID,
	).Scan(&existingClientUpdatedAt, &existingVersion)
	if errors.Is(err, sql.ErrNoRows) {
		return true, nil
	}
	if err != nil {
		return false, err
	}

	incomingTime, err := time.Parse(time.RFC3339Nano, item.ClientUpdatedAt)
	if err != nil {
		return false, err
	}
	existingTime, err := time.Parse(time.RFC3339Nano, existingClientUpdatedAt)
	if err != nil {
		return false, err
	}

	if incomingTime.After(existingTime) {
		return true, nil
	}
	if incomingTime.Equal(existingTime) && item.Version >= existingVersion {
		return true, nil
	}
	return false, nil
}

func nextRevision(tx *sql.Tx) (int64, error) {
	cursor, err := cursorTx(tx)
	if err != nil {
		return 0, err
	}
	cursor++
	_, err = tx.Exec(`UPDATE sync_meta SET value = ? WHERE key = 'revision'`, fmt.Sprintf("%d", cursor))
	return cursor, err
}

func cursorTx(tx *sql.Tx) (int64, error) {
	var cursor int64
	err := tx.QueryRow(`SELECT CAST(value AS INTEGER) FROM sync_meta WHERE key = 'revision'`).Scan(&cursor)
	return cursor, err
}

func upsertItem(tx *sql.Tx, item Item) error {
	_, err := tx.Exec(
		`INSERT INTO sync_items (
			entity_type, entity_id, payload_json, client_updated_at, server_updated_at,
			deleted_at, version, source_device_id, server_revision
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(entity_type, entity_id) DO UPDATE SET
			payload_json = excluded.payload_json,
			client_updated_at = excluded.client_updated_at,
			server_updated_at = excluded.server_updated_at,
			deleted_at = excluded.deleted_at,
			version = excluded.version,
			source_device_id = excluded.source_device_id,
			server_revision = excluded.server_revision`,
		item.EntityType,
		item.EntityID,
		item.PayloadJSON,
		item.ClientUpdatedAt,
		item.ServerUpdatedAt,
		item.DeletedAt,
		item.Version,
		item.SourceDeviceID,
		item.ServerRevision,
	)
	return err
}

func (store *Store) IsEmpty() (bool, error) {
	var value string
	err := store.db.QueryRow(`SELECT value FROM sync_meta WHERE key = 'initialized'`).Scan(&value)
	return value != "1", err
}

func (store *Store) Initialize(mutations []Mutation) ([]MutationResult, int64, error) {
	var results []MutationResult
	var cursor int64
	err := store.withTx(func(tx *sql.Tx) error {
		initialized, err := initializedTx(tx)
		if err != nil {
			return err
		}
		if initialized {
			return errors.New("sync store is already initialized")
		}
		results, cursor, err = applyMutationsTx(tx, mutations)
		if err != nil {
			return err
		}
		_, err = tx.Exec(`UPDATE sync_meta SET value = '1' WHERE key = 'initialized'`)
		return err
	})
	return results, cursor, err
}

func (store *Store) ApplyMutations(mutations []Mutation) ([]MutationResult, int64, error) {
	var results []MutationResult
	var cursor int64
	err := store.withTx(func(tx *sql.Tx) error {
		initialized, err := initializedTx(tx)
		if err != nil {
			return err
		}
		if !initialized {
			return errors.New("sync store is not initialized")
		}
		results, cursor, err = applyMutationsTx(tx, mutations)
		return err
	})
	return results, cursor, err
}

func initializedTx(tx *sql.Tx) (bool, error) {
	var value string
	err := tx.QueryRow(`SELECT value FROM sync_meta WHERE key = 'initialized'`).Scan(&value)
	return value == "1", err
}

func applyMutationsTx(tx *sql.Tx, mutations []Mutation) ([]MutationResult, int64, error) {
	results := make([]MutationResult, 0, len(mutations))
	for _, mutation := range mutations {
		if err := validateMutation(mutation); err != nil {
			return nil, 0, err
		}

		var priorRevision int64
		err := tx.QueryRow(
			`SELECT server_revision FROM applied_mutations WHERE mutation_id = ?`,
			mutation.MutationID,
		).Scan(&priorRevision)
		if err == nil {
			results = append(results, MutationResult{MutationID: mutation.MutationID, Status: "duplicate", ServerRevision: priorRevision})
			continue
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return nil, 0, err
		}

		current, err := headTx(tx, mutation.EntityType, mutation.EntityID)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return nil, 0, err
		}
		currentRevision := int64(0)
		if current != nil {
			currentRevision = current.Revision
		}
		if mutation.BaseRevision != currentRevision {
			results = append(results, MutationResult{
				MutationID:     mutation.MutationID,
				Status:         "conflict",
				ServerRevision: currentRevision,
				Current:        current,
			})
			continue
		}

		revision, err := nextRevision(tx)
		if err != nil {
			return nil, 0, err
		}
		updatedAt := time.Now().UTC().Format(time.RFC3339Nano)
		payload := mutation.PayloadJSON
		if mutation.Operation == "delete" {
			payload = "null"
		}
		change := Change{
			Revision:        revision,
			EntityType:      mutation.EntityType,
			EntityID:        mutation.EntityID,
			Operation:       mutation.Operation,
			PayloadJSON:     payload,
			SourceDeviceID:  mutation.SourceDeviceID,
			ServerUpdatedAt: updatedAt,
		}
		if err := writeChangeTx(tx, change); err != nil {
			return nil, 0, err
		}
		if _, err := tx.Exec(
			`INSERT INTO applied_mutations(mutation_id, server_revision, applied_at) VALUES(?, ?, ?)`,
			mutation.MutationID, revision, updatedAt,
		); err != nil {
			return nil, 0, err
		}
		results = append(results, MutationResult{MutationID: mutation.MutationID, Status: "accepted", ServerRevision: revision})
	}
	cursor, err := cursorTx(tx)
	return results, cursor, err
}

func (store *Store) Changes(afterRevision int64, limit int) ([]Change, int64, bool, error) {
	if limit <= 0 || limit > 500 {
		limit = 200
	}
	rows, err := store.db.Query(
		`SELECT revision, entity_type, entity_id, operation, payload_json, source_device_id, server_updated_at
		 FROM change_log WHERE revision > ? ORDER BY revision ASC LIMIT ?`,
		afterRevision, limit+1,
	)
	if err != nil {
		return nil, 0, false, err
	}
	defer rows.Close()
	changes := make([]Change, 0, limit+1)
	for rows.Next() {
		var change Change
		if err := rows.Scan(
			&change.Revision, &change.EntityType, &change.EntityID, &change.Operation,
			&change.PayloadJSON, &change.SourceDeviceID, &change.ServerUpdatedAt,
		); err != nil {
			return nil, 0, false, err
		}
		changes = append(changes, change)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, false, err
	}
	hasMore := len(changes) > limit
	if hasMore {
		changes = changes[:limit]
	}
	cursor, err := store.Cursor()
	return changes, cursor, hasMore, err
}

// WidgetHeads returns a transactionally consistent, read-only projection source.
// Only current task and project upserts are exposed; tombstones and historical
// payloads stay private to the synchronization API.
func (store *Store) WidgetHeads() ([]Change, int64, error) {
	tx, err := store.db.BeginTx(context.Background(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, 0, err
	}
	defer tx.Rollback()

	rows, err := tx.Query(
		`SELECT revision, entity_type, entity_id, operation, payload_json, source_device_id, server_updated_at
		 FROM entity_heads
		 WHERE operation = 'upsert' AND entity_type IN ('task', 'project')
		 ORDER BY revision ASC`,
	)
	if err != nil {
		return nil, 0, err
	}

	heads := []Change{}
	for rows.Next() {
		var change Change
		if err := rows.Scan(
			&change.Revision, &change.EntityType, &change.EntityID, &change.Operation,
			&change.PayloadJSON, &change.SourceDeviceID, &change.ServerUpdatedAt,
		); err != nil {
			_ = rows.Close()
			return nil, 0, err
		}
		heads = append(heads, change)
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return nil, 0, err
	}
	if err := rows.Close(); err != nil {
		return nil, 0, err
	}

	cursor, err := cursorTx(tx)
	if err != nil {
		return nil, 0, err
	}
	if err := tx.Commit(); err != nil {
		return nil, 0, err
	}
	return heads, cursor, nil
}

func validateMutation(mutation Mutation) error {
	if mutation.MutationID == "" {
		return errors.New("mutationID is required")
	}
	if mutation.EntityType == "" || mutation.EntityID == "" {
		return errors.New("entity type and id are required")
	}
	if mutation.SourceDeviceID == "" {
		return errors.New("deviceID is required")
	}
	if mutation.Operation != "upsert" && mutation.Operation != "delete" {
		return errors.New("operation must be upsert or delete")
	}
	if mutation.Operation == "upsert" && (mutation.PayloadJSON == "" || mutation.PayloadJSON == "null") {
		return errors.New("payload is required for upsert")
	}
	if mutation.BaseRevision < 0 {
		return errors.New("baseRevision must be non-negative")
	}
	if _, err := time.Parse(time.RFC3339Nano, mutation.CreatedAt); err != nil {
		return fmt.Errorf("invalid createdAt: %w", err)
	}
	return nil
}

func headTx(tx *sql.Tx, entityType, entityID string) (*Change, error) {
	var change Change
	err := tx.QueryRow(
		`SELECT revision, entity_type, entity_id, operation, payload_json, source_device_id, server_updated_at
		 FROM entity_heads WHERE entity_type = ? AND entity_id = ?`,
		entityType, entityID,
	).Scan(
		&change.Revision, &change.EntityType, &change.EntityID, &change.Operation,
		&change.PayloadJSON, &change.SourceDeviceID, &change.ServerUpdatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	return &change, err
}

func writeChangeTx(tx *sql.Tx, change Change) error {
	if _, err := tx.Exec(
		`INSERT INTO change_log(revision, entity_type, entity_id, operation, payload_json, source_device_id, server_updated_at)
		 VALUES(?, ?, ?, ?, ?, ?, ?)`,
		change.Revision, change.EntityType, change.EntityID, change.Operation, change.PayloadJSON,
		change.SourceDeviceID, change.ServerUpdatedAt,
	); err != nil {
		return err
	}
	_, err := tx.Exec(
		`INSERT INTO entity_heads(entity_type, entity_id, operation, payload_json, revision, source_device_id, server_updated_at)
		 VALUES(?, ?, ?, ?, ?, ?, ?)
		 ON CONFLICT(entity_type, entity_id) DO UPDATE SET
		 operation=excluded.operation, payload_json=excluded.payload_json, revision=excluded.revision,
		 source_device_id=excluded.source_device_id, server_updated_at=excluded.server_updated_at`,
		change.EntityType, change.EntityID, change.Operation, change.PayloadJSON, change.Revision,
		change.SourceDeviceID, change.ServerUpdatedAt,
	)
	return err
}
