package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

const (
	TelegramQueued     = "queued"
	TelegramProcessing = "processing"
	TelegramCommitted  = "committed"
	TelegramDone       = "done"
	TelegramFailed     = "failed"
)

type TelegramUpdate struct {
	BotID            string
	UpdateID         int64
	ChatID           int64
	MessageDate      int64
	Kind             string
	PayloadJSON      string
	TaskID           string
	Status           string
	AttemptCount     int
	NextAttemptAt    time.Time
	LeaseUntil       *time.Time
	ServerRevision   *int64
	ConfirmationText string
	LastError        string
}

func (store *Store) EnqueueTelegramUpdate(ctx context.Context, update TelegramUpdate, now time.Time) (bool, error) {
	if update.BotID == "" || update.UpdateID <= 0 || update.ChatID == 0 || update.MessageDate <= 0 || update.TaskID == "" {
		return false, errors.New("invalid telegram update identity")
	}
	switch update.Kind {
	case "text", "voice", "help", "unsupported":
	default:
		return false, fmt.Errorf("unsupported telegram update kind %q", update.Kind)
	}
	nowText := formatTelegramQueueTime(now)
	result, err := store.db.ExecContext(ctx, `INSERT OR IGNORE INTO telegram_updates (
		bot_id, update_id, chat_id, message_date, kind, payload_json, task_id,
		status, attempt_count, next_attempt_at, created_at, updated_at
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)`,
		update.BotID, update.UpdateID, update.ChatID, update.MessageDate, update.Kind,
		update.PayloadJSON, update.TaskID, TelegramQueued, nowText, nowText, nowText,
	)
	if err != nil {
		return false, err
	}
	inserted, err := result.RowsAffected()
	return inserted == 1, err
}

func (store *Store) ClaimTelegramUpdate(ctx context.Context, botID string, now time.Time, leaseDuration time.Duration) (*TelegramUpdate, error) {
	var claimed *TelegramUpdate
	err := store.withTx(func(tx *sql.Tx) error {
		nowText := formatTelegramQueueTime(now)
		row := tx.QueryRowContext(ctx, `SELECT
			bot_id, update_id, chat_id, message_date, kind, COALESCE(payload_json, ''), task_id,
			status, attempt_count, next_attempt_at, lease_until, server_revision,
			COALESCE(confirmation_text, ''), COALESCE(last_error, '')
			FROM telegram_updates
			WHERE bot_id = ?
			  AND status IN ('queued', 'processing', 'committed')
			  AND next_attempt_at <= ?
			  AND (lease_until IS NULL OR lease_until <= ?)
			ORDER BY next_attempt_at ASC, update_id ASC
			LIMIT 1`, botID, nowText, nowText)
		var update TelegramUpdate
		var nextAttemptText string
		var leaseText sql.NullString
		var revision sql.NullInt64
		if err := row.Scan(
			&update.BotID, &update.UpdateID, &update.ChatID, &update.MessageDate, &update.Kind,
			&update.PayloadJSON, &update.TaskID, &update.Status, &update.AttemptCount,
			&nextAttemptText, &leaseText, &revision, &update.ConfirmationText, &update.LastError,
		); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return nil
			}
			return err
		}
		parsedNext, err := time.Parse(time.RFC3339Nano, nextAttemptText)
		if err != nil {
			return err
		}
		update.NextAttemptAt = parsedNext
		if leaseText.Valid {
			parsedLease, err := time.Parse(time.RFC3339Nano, leaseText.String)
			if err != nil {
				return err
			}
			update.LeaseUntil = &parsedLease
		}
		if revision.Valid {
			value := revision.Int64
			update.ServerRevision = &value
		}

		claimedStatus := TelegramProcessing
		if update.Status == TelegramCommitted {
			claimedStatus = TelegramCommitted
		}
		leaseUntil := formatTelegramQueueTime(now.Add(leaseDuration))
		result, err := tx.ExecContext(ctx, `UPDATE telegram_updates
			SET status = ?, attempt_count = attempt_count + 1, lease_until = ?, updated_at = ?
			WHERE bot_id = ? AND update_id = ?
			  AND (lease_until IS NULL OR lease_until <= ?)`,
			claimedStatus, leaseUntil, nowText, update.BotID, update.UpdateID, nowText,
		)
		if err != nil {
			return err
		}
		rows, err := result.RowsAffected()
		if err != nil {
			return err
		}
		if rows != 1 {
			return nil
		}
		update.Status = claimedStatus
		update.AttemptCount++
		claimed = &update
		return nil
	})
	return claimed, err
}

func (store *Store) MarkTelegramCommitted(ctx context.Context, botID string, updateID int64, revision int64, confirmation string, now time.Time) error {
	return store.updateTelegramState(ctx, botID, updateID, TelegramCommitted, now, now, revision, confirmation, "", false)
}

func (store *Store) RetryTelegramUpdate(ctx context.Context, botID string, updateID int64, status string, nextAttempt time.Time, errorCode string, now time.Time) error {
	if status != TelegramQueued && status != TelegramCommitted {
		return errors.New("telegram retry status must be queued or committed")
	}
	return store.updateTelegramState(ctx, botID, updateID, status, nextAttempt, now, 0, "", errorCode, false)
}

func (store *Store) FinishTelegramUpdate(ctx context.Context, botID string, updateID int64, status string, errorCode string, now time.Time) error {
	if status != TelegramDone && status != TelegramFailed {
		return errors.New("telegram terminal status must be done or failed")
	}
	return store.updateTelegramState(ctx, botID, updateID, status, now, now, 0, "", errorCode, true)
}

func (store *Store) updateTelegramState(
	ctx context.Context,
	botID string,
	updateID int64,
	status string,
	nextAttempt time.Time,
	now time.Time,
	revision int64,
	confirmation string,
	errorCode string,
	clearPayload bool,
) error {
	query := `UPDATE telegram_updates SET
		status = ?, next_attempt_at = ?, lease_until = NULL,
		server_revision = CASE WHEN ? > 0 THEN ? ELSE server_revision END,
		confirmation_text = CASE WHEN ? <> '' THEN ? ELSE confirmation_text END,
		last_error = NULLIF(?, ''), updated_at = ?`
	if clearPayload {
		query += `, payload_json = NULL, confirmation_text = NULL`
	}
	query += ` WHERE bot_id = ? AND update_id = ?`
	result, err := store.db.ExecContext(ctx, query,
		status, formatTelegramQueueTime(nextAttempt), revision, revision,
		confirmation, confirmation, errorCode, formatTelegramQueueTime(now), botID, updateID,
	)
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows != 1 {
		return errors.New("telegram update not found")
	}
	return nil
}

func formatTelegramQueueTime(value time.Time) string {
	return value.UTC().Format("2006-01-02T15:04:05.000000000Z")
}

func (store *Store) TelegramUpdate(ctx context.Context, botID string, updateID int64) (*TelegramUpdate, error) {
	row := store.db.QueryRowContext(ctx, `SELECT
		bot_id, update_id, chat_id, message_date, kind, COALESCE(payload_json, ''), task_id,
		status, attempt_count, next_attempt_at, lease_until, server_revision,
		COALESCE(confirmation_text, ''), COALESCE(last_error, '')
		FROM telegram_updates WHERE bot_id = ? AND update_id = ?`, botID, updateID)
	var update TelegramUpdate
	var nextAttemptText string
	var leaseText sql.NullString
	var revision sql.NullInt64
	if err := row.Scan(
		&update.BotID, &update.UpdateID, &update.ChatID, &update.MessageDate, &update.Kind,
		&update.PayloadJSON, &update.TaskID, &update.Status, &update.AttemptCount,
		&nextAttemptText, &leaseText, &revision, &update.ConfirmationText, &update.LastError,
	); err != nil {
		return nil, err
	}
	parsedNext, err := time.Parse(time.RFC3339Nano, nextAttemptText)
	if err != nil {
		return nil, err
	}
	update.NextAttemptAt = parsedNext
	if leaseText.Valid {
		parsedLease, err := time.Parse(time.RFC3339Nano, leaseText.String)
		if err != nil {
			return nil, err
		}
		update.LeaseUntil = &parsedLease
	}
	if revision.Valid {
		value := revision.Int64
		update.ServerRevision = &value
	}
	return &update, nil
}
