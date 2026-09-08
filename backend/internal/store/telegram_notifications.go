package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// TelegramNotification is a durable outbound notification. EventKey is the
// idempotency key and must be stable across scheduler restarts.
type TelegramNotification struct {
	BotID         string
	EventKey      string
	ChatID        int64
	Kind          string
	TaskID        string
	EventTime     time.Time
	PayloadJSON   string
	MetadataJSON  string
	Status        string
	AttemptCount  int
	NextAttemptAt time.Time
	LeaseUntil    *time.Time
	LastError     string
}

func (store *Store) EnqueueTelegramNotification(ctx context.Context, notification TelegramNotification, now time.Time) (bool, error) {
	if notification.BotID == "" || notification.EventKey == "" || notification.ChatID == 0 || notification.Kind == "" || notification.EventTime.IsZero() {
		return false, errors.New("invalid telegram notification identity")
	}
	nowText := formatTelegramQueueTime(now)
	result, err := store.db.ExecContext(ctx, `INSERT OR IGNORE INTO telegram_notifications
		(bot_id, event_key, chat_id, kind, task_id, event_time, payload_json, metadata_json,
		 status, attempt_count, next_attempt_at, created_at, updated_at)
		VALUES (?, ?, ?, ?, NULLIF(?, ''), ?, NULLIF(?, ''), NULLIF(?, ''), 'queued', 0, ?, ?, ?)`,
		notification.BotID, notification.EventKey, notification.ChatID, notification.Kind,
		notification.TaskID, formatTelegramQueueTime(notification.EventTime), notification.PayloadJSON,
		notification.MetadataJSON, nowText, nowText, nowText)
	if err != nil {
		return false, err
	}
	count, err := result.RowsAffected()
	return count == 1, err
}

// ClaimTelegramNotification atomically leases the oldest eligible event.
// Expired processing leases are reclaimed, making delivery recoverable after a crash.
func (store *Store) ClaimTelegramNotification(ctx context.Context, botID string, now time.Time, lease time.Duration) (*TelegramNotification, error) {
	var result *TelegramNotification
	err := store.withTx(func(tx *sql.Tx) error {
		nowText := formatTelegramQueueTime(now)
		row := tx.QueryRowContext(ctx, `SELECT id, bot_id, event_key, chat_id, kind,
			COALESCE(task_id, ''), event_time, COALESCE(payload_json, ''), COALESCE(metadata_json, ''),
			status, attempt_count, next_attempt_at, lease_until, COALESCE(last_error, '')
			FROM telegram_notifications
			WHERE bot_id = ? AND status IN ('queued', 'processing') AND next_attempt_at <= ?
			  AND (lease_until IS NULL OR lease_until <= ?)
			ORDER BY next_attempt_at ASC, id ASC LIMIT 1`, botID, nowText, nowText)
		var id int64
		var n TelegramNotification
		var eventText, nextText string
		var leaseText, taskID sql.NullString
		if err := row.Scan(&id, &n.BotID, &n.EventKey, &n.ChatID, &n.Kind, &taskID, &eventText,
			&n.PayloadJSON, &n.MetadataJSON, &n.Status, &n.AttemptCount, &nextText, &leaseText, &n.LastError); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return nil
			}
			return err
		}
		n.TaskID = taskID.String
		var err error
		if n.EventTime, err = time.Parse(time.RFC3339Nano, eventText); err != nil {
			return err
		}
		if n.NextAttemptAt, err = time.Parse(time.RFC3339Nano, nextText); err != nil {
			return err
		}
		if leaseText.Valid {
			value, err := time.Parse(time.RFC3339Nano, leaseText.String)
			if err != nil {
				return err
			}
			n.LeaseUntil = &value
		}
		leaseTextValue := formatTelegramQueueTime(now.Add(lease))
		updated, err := tx.ExecContext(ctx, `UPDATE telegram_notifications SET status='processing', attempt_count=attempt_count+1, lease_until=?, updated_at=? WHERE id=? AND (lease_until IS NULL OR lease_until <= ?)`, leaseTextValue, nowText, id, nowText)
		if err != nil {
			return err
		}
		count, err := updated.RowsAffected()
		if err != nil {
			return err
		}
		if count == 1 {
			n.Status = "processing"
			n.AttemptCount++
			value, _ := time.Parse(time.RFC3339Nano, leaseTextValue)
			n.LeaseUntil = &value
			result = &n
		}
		return nil
	})
	return result, err
}

func (store *Store) RetryTelegramNotification(ctx context.Context, botID, eventKey string, attemptCount int, nextAttempt time.Time, errorText string, now time.Time) error {
	result, err := store.db.ExecContext(ctx, `UPDATE telegram_notifications SET status='queued', next_attempt_at=?, lease_until=NULL, last_error=NULLIF(?, ''), updated_at=? WHERE bot_id=? AND event_key=? AND status='processing' AND attempt_count=?`, formatTelegramQueueTime(nextAttempt), errorText, formatTelegramQueueTime(now), botID, eventKey, attemptCount)
	if err != nil {
		return err
	}
	count, err := result.RowsAffected()
	if err == nil && count != 1 {
		return errors.New("telegram notification lease lost")
	}
	return err
}

func (store *Store) FinishTelegramNotification(ctx context.Context, botID, eventKey string, attemptCount int, status, errorText string, now time.Time) error {
	if status != "done" && status != "failed" {
		return fmt.Errorf("invalid terminal notification status %q", status)
	}
	result, err := store.db.ExecContext(ctx, `UPDATE telegram_notifications SET status=?, next_attempt_at=?, lease_until=NULL, last_error=NULLIF(?, ''), updated_at=? WHERE bot_id=? AND event_key=? AND status='processing' AND attempt_count=?`, status, formatTelegramQueueTime(now), errorText, formatTelegramQueueTime(now), botID, eventKey, attemptCount)
	if err != nil {
		return err
	}
	count, err := result.RowsAffected()
	if err == nil && count != 1 {
		return errors.New("telegram notification lease lost")
	}
	return err
}

// TelegramNotification returns an event by its stable idempotency key.
func (store *Store) TelegramNotification(ctx context.Context, botID, eventKey string) (*TelegramNotification, error) {
	row := store.db.QueryRowContext(ctx, `SELECT bot_id,event_key,chat_id,kind,COALESCE(task_id,''),event_time,COALESCE(payload_json,''),COALESCE(metadata_json,''),status,attempt_count,next_attempt_at,lease_until,COALESCE(last_error,'') FROM telegram_notifications WHERE bot_id=? AND event_key=?`, botID, eventKey)
	var n TelegramNotification
	var task, event, next string
	var lease sql.NullString
	if err := row.Scan(&n.BotID, &n.EventKey, &n.ChatID, &n.Kind, &task, &event, &n.PayloadJSON, &n.MetadataJSON, &n.Status, &n.AttemptCount, &next, &lease, &n.LastError); err != nil {
		return nil, err
	}
	n.TaskID = task
	var err error
	if n.EventTime, err = time.Parse(time.RFC3339Nano, event); err != nil {
		return nil, err
	}
	if n.NextAttemptAt, err = time.Parse(time.RFC3339Nano, next); err != nil {
		return nil, err
	}
	if lease.Valid {
		v, e := time.Parse(time.RFC3339Nano, lease.String)
		if e != nil {
			return nil, e
		}
		n.LeaseUntil = &v
	}
	return &n, nil
}

// NotificationHeads returns current non-deleted task and project payloads.
func (store *Store) NotificationHeads(ctx context.Context) ([]Change, error) {
	rows, err := store.db.QueryContext(ctx, `SELECT revision,entity_type,entity_id,operation,payload_json,source_device_id,server_updated_at FROM entity_heads WHERE operation='upsert' AND entity_type IN ('task','project') ORDER BY entity_type, entity_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var heads []Change
	for rows.Next() {
		var c Change
		if err := rows.Scan(&c.Revision, &c.EntityType, &c.EntityID, &c.Operation, &c.PayloadJSON, &c.SourceDeviceID, &c.ServerUpdatedAt); err != nil {
			return nil, err
		}
		heads = append(heads, c)
	}
	return heads, rows.Err()
}

// CurrentHead reads a task or project head, including tombstones, for scheduler revalidation.
func (store *Store) CurrentHead(ctx context.Context, entityType, entityID string) (*Change, error) {
	row := store.db.QueryRowContext(ctx, `SELECT revision,entity_type,entity_id,operation,payload_json,source_device_id,server_updated_at FROM entity_heads WHERE entity_type=? AND entity_id=?`, entityType, entityID)
	var c Change
	if err := row.Scan(&c.Revision, &c.EntityType, &c.EntityID, &c.Operation, &c.PayloadJSON, &c.SourceDeviceID, &c.ServerUpdatedAt); err != nil {
		return nil, err
	}
	return &c, nil
}

// TaskHead is a convenience wrapper used when revalidating a reminder before delivery.
func (store *Store) TaskHead(ctx context.Context, taskID string) (*Change, error) {
	return store.CurrentHead(ctx, "task", taskID)
}
