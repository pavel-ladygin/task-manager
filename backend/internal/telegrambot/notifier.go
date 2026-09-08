package telegrambot

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sort"
	"strings"
	"time"

	"planner-sync/internal/store"
)

const (
	notificationPollInterval = 15 * time.Second
	reminderLeadTime         = 15 * time.Minute
	morningDigestHour        = 7
	maximumTelegramText      = 4096
	notificationMorning      = "morning"
	notificationReminder     = "reminder"
)

type notificationStore interface {
	NotificationHeads(context.Context) ([]store.Change, error)
	EnqueueTelegramNotification(context.Context, store.TelegramNotification, time.Time) (bool, error)
	ClaimTelegramNotification(context.Context, string, time.Time, time.Duration) (*store.TelegramNotification, error)
	RetryTelegramNotification(context.Context, string, string, int, time.Time, string, time.Time) error
	FinishTelegramNotification(context.Context, string, string, int, string, string, time.Time) error
}

type messageSender interface {
	SendMessage(context.Context, int64, string) error
}

// Notifier discovers notification events and delivers them through a durable queue.
// Its initial scan boundary is deliberately kept in memory: events missed while the
// process was stopped are not backfilled.
type Notifier struct {
	store    notificationStore
	api      messageSender
	botID    string
	chatID   int64
	location *time.Location
	logger   *log.Logger
	now      func() time.Time
}

func NewNotifier(notificationStore notificationStore, api messageSender, botID string, chatID int64, location *time.Location, logger *log.Logger) *Notifier {
	if logger == nil {
		logger = log.Default()
	}
	return &Notifier{
		store: notificationStore, api: api, botID: botID, chatID: chatID,
		location: location, logger: logger, now: time.Now,
	}
}

func (notifier *Notifier) Run(ctx context.Context) {
	ticker := time.NewTicker(notificationPollInterval)
	defer ticker.Stop()
	lastCheck := notifier.now()
	if err := notifier.Scan(ctx, lastCheck.Add(-time.Nanosecond), lastCheck); err != nil {
		notifier.logger.Printf("telegram notifier initial scan error: %v", err)
	}
	notifier.drain(ctx)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			current := notifier.now()
			if err := notifier.Scan(ctx, lastCheck, current); err != nil {
				notifier.logger.Printf("telegram notifier scan error: %v", err)
			}
			lastCheck = current
			notifier.drain(ctx)
		}
	}
}

func (notifier *Notifier) drain(ctx context.Context) {
	for {
		worked, err := notifier.ProcessNext(ctx)
		if err != nil {
			notifier.logger.Printf("telegram notifier delivery error: %v", err)
			return
		}
		if !worked {
			return
		}
	}
}

// Scan enqueues events whose trigger is in the half-open runtime interval
// (previous, current]. Callers must not persist previous across restarts.
func (notifier *Notifier) Scan(ctx context.Context, previous, current time.Time) error {
	if notifier == nil || notifier.store == nil || notifier.location == nil || !current.After(previous) {
		return nil
	}
	heads, err := notifier.store.NotificationHeads(ctx)
	if err != nil {
		return err
	}
	tasks, projects := decodeNotificationHeads(heads)

	localCurrent := current.In(notifier.location)
	dayStart := time.Date(localCurrent.Year(), localCurrent.Month(), localCurrent.Day(), 0, 0, 0, 0, notifier.location)
	digestAt := time.Date(localCurrent.Year(), localCurrent.Month(), localCurrent.Day(), morningDigestHour, 0, 0, 0, notifier.location)
	if crossed(previous, current, digestAt) {
		dateKey := dayStart.Format("2006-01-02")
		_, err = notifier.store.EnqueueTelegramNotification(ctx, store.TelegramNotification{
			BotID: notifier.botID, EventKey: "morning:" + dateKey, ChatID: notifier.chatID,
			Kind: notificationMorning, EventTime: digestAt,
			PayloadJSON: notificationPayload(formatMorningDigest(tasks, projects, dayStart, notifier.location)),
		}, current)
		if err != nil {
			return err
		}
	}

	for _, task := range tasks {
		if !task.active() || task.Scheduled == nil {
			continue
		}
		scheduled, err := time.Parse(time.RFC3339Nano, *task.Scheduled)
		if err != nil {
			continue
		}
		trigger := scheduled.Add(-reminderLeadTime)
		if !crossed(previous, current, trigger) || !scheduled.After(current) {
			continue
		}
		// A task created or rescheduled after its trigger must not be caught up.
		if task.UpdatedAt != "" {
			updated, parseErr := time.Parse(time.RFC3339Nano, task.UpdatedAt)
			if parseErr == nil && updated.After(trigger) {
				continue
			}
		}
		if task.ServerUpdatedAt != "" {
			arrived, parseErr := time.Parse(time.RFC3339Nano, task.ServerUpdatedAt)
			if parseErr != nil || arrived.After(trigger) {
				continue
			}
		}
		eventTime := scheduled.UTC().Format(time.RFC3339Nano)
		_, err = notifier.store.EnqueueTelegramNotification(ctx, store.TelegramNotification{
			BotID: notifier.botID, EventKey: "reminder:" + task.ID + ":" + eventTime,
			ChatID: notifier.chatID, Kind: notificationReminder,
			TaskID: task.ID, EventTime: scheduled,
			PayloadJSON: notificationPayload(formatReminder(task, projects[projectKey(task.ProjectID)], scheduled, notifier.location)),
		}, current)
		if err != nil {
			return err
		}
	}
	return nil
}

func (notifier *Notifier) ProcessNext(ctx context.Context) (bool, error) {
	now := notifier.now()
	notification, err := notifier.store.ClaimTelegramNotification(ctx, notifier.botID, now, 90*time.Second)
	if err != nil || notification == nil {
		return false, err
	}
	if notification.Kind == notificationReminder {
		valid, err := notifier.reminderIsCurrent(ctx, *notification)
		if err != nil {
			return true, notifier.retry(ctx, *notification, "task_revalidation")
		}
		if !valid {
			return true, notifier.store.FinishTelegramNotification(ctx, notification.BotID, notification.EventKey, notification.AttemptCount, "done", "cancelled", now)
		}
	}
	message, err := notificationMessage(notification.PayloadJSON)
	if err != nil {
		return true, notifier.store.FinishTelegramNotification(ctx, notification.BotID, notification.EventKey, notification.AttemptCount, "failed", "invalid_payload", now)
	}
	if err := notifier.api.SendMessage(ctx, notification.ChatID, message); err != nil {
		return true, notifier.retry(ctx, *notification, "telegram_send")
	}
	return true, notifier.store.FinishTelegramNotification(ctx, notification.BotID, notification.EventKey, notification.AttemptCount, "done", "", now)
}

func notificationPayload(message string) string {
	payload, _ := json.Marshal(struct {
		Message string `json:"message"`
	}{Message: message})
	return string(payload)
}

func notificationMessage(payload string) (string, error) {
	var value struct {
		Message string `json:"message"`
	}
	if err := json.Unmarshal([]byte(payload), &value); err != nil || value.Message == "" {
		return "", fmt.Errorf("invalid notification payload")
	}
	return value.Message, nil
}

func (notifier *Notifier) retry(ctx context.Context, notification store.TelegramNotification, code string) error {
	if notification.AttemptCount >= 5 {
		return notifier.store.FinishTelegramNotification(ctx, notification.BotID, notification.EventKey, notification.AttemptCount, "failed", code, notifier.now())
	}
	return notifier.store.RetryTelegramNotification(ctx, notification.BotID, notification.EventKey, notification.AttemptCount, notifier.now().Add(retryDelay(notification.AttemptCount)), code, notifier.now())
}

func (notifier *Notifier) reminderIsCurrent(ctx context.Context, notification store.TelegramNotification) (bool, error) {
	heads, err := notifier.store.NotificationHeads(ctx)
	if err != nil {
		return false, err
	}
	for _, head := range heads {
		if head.EntityType != "task" || head.EntityID != notification.TaskID {
			continue
		}
		var task notificationTask
		if err := json.Unmarshal([]byte(head.PayloadJSON), &task); err != nil {
			return false, err
		}
		if !task.active() || task.Scheduled == nil {
			return false, nil
		}
		scheduled, err := time.Parse(time.RFC3339Nano, *task.Scheduled)
		return err == nil && scheduled.Equal(notification.EventTime), err
	}
	return false, nil
}

func crossed(previous, current, event time.Time) bool {
	return event.After(previous) && !event.After(current)
}

type notificationTask struct {
	ID        string  `json:"id"`
	Title     string  `json:"title"`
	Status    string  `json:"status"`
	Priority  string  `json:"priority"`
	Scheduled *string `json:"scheduled"`
	Due       *string `json:"due"`
	UpdatedAt string  `json:"updatedAt"`
	ProjectID *string `json:"projectID"`
	// ServerUpdatedAt is populated from the head metadata, not from the payload.
	ServerUpdatedAt string `json:"-"`
}

func (task notificationTask) active() bool {
	return task.Status != "done" && task.Status != "cancelled"
}

type notificationProject struct {
	ID    string `json:"id"`
	Title string `json:"title"`
}

func decodeNotificationHeads(heads []store.Change) ([]notificationTask, map[string]notificationProject) {
	tasks := make([]notificationTask, 0)
	projects := make(map[string]notificationProject)
	for _, head := range heads {
		switch head.EntityType {
		case "task":
			var task notificationTask
			if json.Unmarshal([]byte(head.PayloadJSON), &task) == nil {
				task.ServerUpdatedAt = head.ServerUpdatedAt
				tasks = append(tasks, task)
			}
		case "project":
			var project notificationProject
			if json.Unmarshal([]byte(head.PayloadJSON), &project) == nil {
				projects[project.ID] = project
			}
		}
	}
	return tasks, projects
}

func projectKey(id *string) string {
	if id == nil {
		return ""
	}
	return *id
}

type digestTask struct {
	task     notificationTask
	category int
	moment   time.Time
	label    string
}

func formatMorningDigest(tasks []notificationTask, projects map[string]notificationProject, dayStart time.Time, location *time.Location) string {
	dayEnd := dayStart.AddDate(0, 0, 1).Add(-time.Nanosecond)
	rows := make([]digestTask, 0)
	for _, task := range tasks {
		if !task.active() {
			continue
		}
		row, ok := digestRow(task, dayStart, dayEnd, location)
		if ok {
			rows = append(rows, row)
		}
	}
	date := russianDate(dayStart)
	if len(rows) == 0 {
		return fmt.Sprintf("☀️ Доброе утро!\n📅 %s\n\nСегодня задач нет — можно посвятить день важному или просто отдохнуть ✨", date)
	}
	sort.SliceStable(rows, func(i, j int) bool {
		if rows[i].category != rows[j].category {
			return rows[i].category < rows[j].category
		}
		if !rows[i].moment.Equal(rows[j].moment) {
			return rows[i].moment.Before(rows[j].moment)
		}
		if priorityRank(rows[i].task.Priority) != priorityRank(rows[j].task.Priority) {
			return priorityRank(rows[i].task.Priority) < priorityRank(rows[j].task.Priority)
		}
		return rows[i].task.Title < rows[j].task.Title
	})

	builder := strings.Builder{}
	builder.WriteString("☀️ Доброе утро!\n📅 ")
	builder.WriteString(date)
	builder.WriteString(fmt.Sprintf("\n📋 Задач: %d\n", len(rows)))
	shown := 0
	for _, row := range rows {
		line := "\n" + row.label + " " + priorityIcon(row.task.Priority) + truncateRunes(strings.TrimSpace(row.task.Title), 180)
		if project := projects[projectKey(row.task.ProjectID)]; project.Title != "" {
			line += " · " + truncateRunes(strings.TrimSpace(project.Title), 80)
		}
		if len([]rune(builder.String()+line)) > maximumTelegramText-40 {
			suffix := fmt.Sprintf("\n\n…и ещё %d задач", len(rows)-shown)
			prefix := truncateRunes(builder.String(), maximumTelegramText-len([]rune(suffix)))
			return prefix + suffix
		}
		if len([]rune(builder.String()+line)) > maximumTelegramText {
			break
		}
		builder.WriteString(line)
		shown++
	}
	return truncateRunes(builder.String(), maximumTelegramText)
}

func digestRow(task notificationTask, dayStart, dayEnd time.Time, location *time.Location) (digestTask, bool) {
	scheduled, hasScheduled := parseMoment(task.Scheduled, location)
	due, hasDue := parseMoment(task.Due, location)
	if (!hasScheduled || scheduled.After(dayEnd)) && (!hasDue || due.After(dayEnd)) {
		return digestTask{}, false
	}
	if (hasScheduled && scheduled.Before(dayStart)) || (hasDue && due.Before(dayStart)) {
		moment := scheduled
		if !hasScheduled || (hasDue && due.Before(moment)) {
			moment = due
		}
		return digestTask{task: task, category: 0, moment: moment, label: "⚠️ Просрочено —"}, true
	}
	if hasScheduled && !scheduled.Before(dayStart) && !scheduled.After(dayEnd) {
		return digestTask{task: task, category: 1, moment: scheduled, label: "⏰ " + scheduled.Format("15:04") + " —"}, true
	}
	return digestTask{task: task, category: 2, moment: due, label: "📌 срок " + due.Format("15:04") + " —"}, true
}

func parseMoment(value *string, location *time.Location) (time.Time, bool) {
	if value == nil {
		return time.Time{}, false
	}
	parsed, err := time.Parse(time.RFC3339Nano, *value)
	if err != nil {
		return time.Time{}, false
	}
	return parsed.In(location), true
}

func formatReminder(task notificationTask, project notificationProject, scheduled time.Time, location *time.Location) string {
	message := "⏰ Через 15 минут\n" + scheduled.In(location).Format("15:04") + " — " + priorityIcon(task.Priority) + truncateRunes(strings.TrimSpace(task.Title), 3600)
	if project.Title != "" {
		message += "\n📁 " + truncateRunes(strings.TrimSpace(project.Title), 300)
	}
	return truncateRunes(message, maximumTelegramText)
}

func priorityRank(priority string) int {
	switch priority {
	case "urgent":
		return 0
	case "high":
		return 1
	case "medium":
		return 2
	case "low":
		return 3
	default:
		return 4
	}
}

func priorityIcon(priority string) string {
	switch priority {
	case "urgent":
		return "🟣 "
	case "high":
		return "🔴 "
	case "medium":
		return "🟡 "
	case "low":
		return "🔵 "
	default:
		return ""
	}
}

func russianDate(value time.Time) string {
	weekdays := []string{"воскресенье", "понедельник", "вторник", "среда", "четверг", "пятница", "суббота"}
	months := []string{"", "января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"}
	return fmt.Sprintf("%s, %d %s", weekdays[value.Weekday()], value.Day(), months[value.Month()])
}
