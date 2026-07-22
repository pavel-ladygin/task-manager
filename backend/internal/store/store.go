package store

import (
	"database/sql"
	"errors"
	"fmt"
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
	statements := []string{
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
	}

	for _, statement := range statements {
		if _, err := store.db.Exec(statement); err != nil {
			return err
		}
	}
	return nil
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

func (store *Store) Bootstrap(items []Item) (cursor int64, err error) {
	err = store.withTx(func(tx *sql.Tx) error {
		if _, err := tx.Exec(`DELETE FROM sync_items`); err != nil {
			return err
		}
		if _, err := tx.Exec(`UPDATE sync_meta SET value = '0' WHERE key = 'revision'`); err != nil {
			return err
		}

		for _, item := range items {
			if err := validateItem(item); err != nil {
				return err
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
		}

		var err error
		cursor, err = cursorTx(tx)
		return err
	})
	return cursor, err
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
