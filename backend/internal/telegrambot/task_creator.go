package telegrambot

import (
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"planner-sync/internal/store"
	"planner-sync/internal/taskparser"
)

type mutationStore interface {
	ApplyMutations([]store.Mutation) ([]store.MutationResult, int64, error)
}

type TaskCreator struct {
	store mutationStore
}

func NewTaskCreator(syncStore mutationStore) *TaskCreator {
	return &TaskCreator{store: syncStore}
}

type taskPayload struct {
	ID                   string            `json:"id"`
	Title                string            `json:"title"`
	Notes                string            `json:"notes"`
	Status               string            `json:"status"`
	Priority             string            `json:"priority"`
	Recurrence           string            `json:"recurrence"`
	RecurrenceSeriesID   *string           `json:"recurrenceSeriesID"`
	RecurrenceAnchorDate *string           `json:"recurrenceAnchorDate"`
	RecurrenceSequence   int               `json:"recurrenceSequence"`
	ShowInKanban         bool              `json:"showInKanban"`
	Scheduled            *string           `json:"scheduled"`
	Due                  *string           `json:"due"`
	CreatedAt            string            `json:"createdAt"`
	UpdatedAt            string            `json:"updatedAt"`
	CompletedAt          *string           `json:"completedAt"`
	ProjectID            *string           `json:"projectID"`
	TagIDs               []string          `json:"tagIDs"`
	ChecklistItems       []json.RawMessage `json:"checklistItems"`
	ManualOrder          float64           `json:"manualOrder"`
}

func (creator *TaskCreator) Create(update store.TelegramUpdate, draft taskparser.Draft, location *time.Location) (int64, error) {
	if creator == nil || creator.store == nil {
		return 0, errors.New("task store is not configured")
	}
	createdAt := time.Unix(update.MessageDate, 0).In(location).Format(time.RFC3339Nano)
	payload := taskPayload{
		ID: update.TaskID, Title: draft.Title, Notes: "", Status: draft.Status, Priority: "none",
		Recurrence: "none", RecurrenceSequence: 0, ShowInKanban: true,
		CreatedAt: createdAt, UpdatedAt: createdAt, TagIDs: []string{}, ChecklistItems: []json.RawMessage{}, ManualOrder: 0,
	}
	if draft.Scheduled != nil {
		value := draft.Scheduled.Format(time.RFC3339Nano)
		payload.Scheduled = &value
	}
	if draft.Due != nil {
		value := draft.Due.Format(time.RFC3339Nano)
		payload.Due = &value
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return 0, err
	}
	mutationID := fmt.Sprintf("telegram:%s:%d", update.BotID, update.UpdateID)
	results, _, err := creator.store.ApplyMutations([]store.Mutation{{
		MutationID: mutationID, EntityType: "task", EntityID: update.TaskID, Operation: "upsert",
		PayloadJSON: string(encoded), BaseRevision: 0, CreatedAt: createdAt,
		SourceDeviceID: "telegram-bot:" + update.BotID,
	}})
	if err != nil {
		return 0, err
	}
	if len(results) != 1 || (results[0].Status != "accepted" && results[0].Status != "duplicate") {
		return 0, errors.New("task mutation was not accepted")
	}
	return results[0].ServerRevision, nil
}
