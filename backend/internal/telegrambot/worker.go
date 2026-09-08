package telegrambot

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strings"
	"time"

	"planner-sync/internal/store"
	"planner-sync/internal/stt"
	"planner-sync/internal/taskparser"
)

type workerStore interface {
	ClaimTelegramUpdate(context.Context, string, time.Time, time.Duration) (*store.TelegramUpdate, error)
	MarkTelegramCommitted(context.Context, string, int64, int64, string, time.Time) error
	RetryTelegramUpdate(context.Context, string, int64, string, time.Time, string, time.Time) error
	FinishTelegramUpdate(context.Context, string, int64, string, string, time.Time) error
}

type taskCreator interface {
	Create(store.TelegramUpdate, taskparser.Draft, *time.Location) (int64, error)
}

type Worker struct {
	store       workerStore
	api         API
	transcriber stt.Transcriber
	creator     taskCreator
	botID       string
	location    *time.Location
	logger      *log.Logger
	notify      chan struct{}
	now         func() time.Time
}

func NewWorker(queue workerStore, api API, transcriber stt.Transcriber, creator taskCreator, botID string, location *time.Location, logger *log.Logger) *Worker {
	if logger == nil {
		logger = log.Default()
	}
	return &Worker{
		store: queue, api: api, transcriber: transcriber, creator: creator,
		botID: botID, location: location, logger: logger, notify: make(chan struct{}, 1), now: time.Now,
	}
}

func (worker *Worker) Notify() {
	select {
	case worker.notify <- struct{}{}:
	default:
	}
}

func (worker *Worker) Run(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	worker.Notify()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		case <-worker.notify:
		}
		for {
			worked, err := worker.ProcessNext(ctx)
			if err != nil {
				worker.logger.Printf("telegram worker error: %v", err)
				break
			}
			if !worked {
				break
			}
		}
	}
}

func (worker *Worker) ProcessNext(ctx context.Context) (bool, error) {
	now := worker.now()
	update, err := worker.store.ClaimTelegramUpdate(ctx, worker.botID, now, 90*time.Second)
	if err != nil || update == nil {
		return false, err
	}
	started := time.Now()
	if update.Status == store.TelegramCommitted {
		err := worker.deliverConfirmation(ctx, *update)
		worker.logger.Printf("telegram update=%d kind=%s stage=confirmation duration=%s", update.UpdateID, update.Kind, time.Since(started).Round(time.Millisecond))
		return true, err
	}
	err = worker.process(ctx, *update)
	worker.logger.Printf("telegram update=%d kind=%s stage=processing duration=%s", update.UpdateID, update.Kind, time.Since(started).Round(time.Millisecond))
	return true, err
}

func (worker *Worker) process(ctx context.Context, update store.TelegramUpdate) error {
	var payload queuedPayload
	if err := json.Unmarshal([]byte(update.PayloadJSON), &payload); err != nil {
		return worker.fail(ctx, update, "invalid_payload", "Не удалось обработать сообщение. Отправьте команду ещё раз.")
	}
	switch update.Kind {
	case "help":
		return worker.finishWithReply(ctx, update, helpText())
	case "unsupported":
		message := "Поддерживаются текст и голосовые сообщения до 30 секунд и 1 МБ.\n\n" + helpText()
		if payload.Reason == "voice_too_large" {
			message = "Голосовое слишком длинное. Максимум — 30 секунд и 1 МБ."
		}
		return worker.finishWithReply(ctx, update, message)
	}

	input := payload.Text
	voice := update.Kind == "voice"
	if voice {
		if payload.Duration <= 0 || payload.Duration > maximumVoiceSeconds || payload.FileSize > maximumVoiceBytes {
			return worker.fail(ctx, update, "invalid_voice", "Голосовое должно быть не длиннее 30 секунд и не больше 1 МБ.")
		}
		audio, err := worker.api.DownloadVoice(ctx, payload.FileID, maximumVoiceBytes)
		if err != nil {
			if errors.Is(err, ErrVoiceTooLarge) || errors.Is(err, ErrInvalidVoice) {
				return worker.fail(ctx, update, "invalid_voice", "Не удалось прочитать голосовое. Повторите запись или отправьте текст.")
			}
			return worker.retryProcessing(ctx, update, "telegram_download")
		}
		if worker.transcriber == nil {
			return worker.fail(ctx, update, "stt_unconfigured", "Распознавание голоса пока не настроено. Отправьте команду текстом.")
		}
		input, err = worker.transcriber.Transcribe(ctx, audio)
		if err != nil {
			return worker.fail(ctx, update, "stt_failed", "Не удалось распознать голос. Повторите запись или отправьте команду текстом.")
		}
	}

	messageTime := time.Unix(update.MessageDate, 0)
	draft, err := taskparser.Parse(input, messageTime, worker.location)
	if err != nil {
		return worker.fail(ctx, update, parserErrorCode(err), parserHelp(err))
	}
	revision, err := worker.creator.Create(update, draft, worker.location)
	if err != nil {
		if strings.Contains(err.Error(), "not initialized") {
			return worker.fail(ctx, update, "store_not_initialized", "Сначала инициализируйте синхронизацию в приложении, затем повторите команду.")
		}
		return worker.retryProcessing(ctx, update, "task_create")
	}
	confirmation := confirmationText(input, draft, messageTime, worker.location, voice)
	return worker.store.MarkTelegramCommitted(ctx, update.BotID, update.UpdateID, revision, confirmation, worker.now())
}

func (worker *Worker) deliverConfirmation(ctx context.Context, update store.TelegramUpdate) error {
	if err := worker.api.SendMessage(ctx, update.ChatID, update.ConfirmationText); err != nil {
		if update.AttemptCount < 5 {
			return worker.store.RetryTelegramUpdate(ctx, update.BotID, update.UpdateID, store.TelegramCommitted, worker.now().Add(retryDelay(update.AttemptCount)), "telegram_send", worker.now())
		}
		return worker.store.FinishTelegramUpdate(ctx, update.BotID, update.UpdateID, store.TelegramDone, "confirmation_failed", worker.now())
	}
	return worker.store.FinishTelegramUpdate(ctx, update.BotID, update.UpdateID, store.TelegramDone, "", worker.now())
}

func (worker *Worker) finishWithReply(ctx context.Context, update store.TelegramUpdate, message string) error {
	if err := worker.api.SendMessage(ctx, update.ChatID, message); err != nil {
		return worker.retryProcessing(ctx, update, "telegram_send")
	}
	return worker.store.FinishTelegramUpdate(ctx, update.BotID, update.UpdateID, store.TelegramDone, "", worker.now())
}

func (worker *Worker) fail(ctx context.Context, update store.TelegramUpdate, errorCode string, message string) error {
	_ = worker.api.SendMessage(ctx, update.ChatID, message)
	return worker.store.FinishTelegramUpdate(ctx, update.BotID, update.UpdateID, store.TelegramFailed, errorCode, worker.now())
}

func (worker *Worker) retryProcessing(ctx context.Context, update store.TelegramUpdate, errorCode string) error {
	if update.AttemptCount >= 5 {
		return worker.fail(ctx, update, errorCode, "Не удалось создать задачу из-за временной ошибки. Повторите команду позже.")
	}
	return worker.store.RetryTelegramUpdate(ctx, update.BotID, update.UpdateID, store.TelegramQueued, worker.now().Add(retryDelay(update.AttemptCount)), errorCode, worker.now())
}

func retryDelay(attempt int) time.Duration {
	delays := []time.Duration{5 * time.Second, 30 * time.Second, 2 * time.Minute, 10 * time.Minute}
	if attempt <= 0 {
		return delays[0]
	}
	index := attempt - 1
	if index >= len(delays) {
		index = len(delays) - 1
	}
	return delays[index]
}

func parserErrorCode(err error) string {
	var parseError *taskparser.ParseError
	if errors.As(err, &parseError) {
		return string(parseError.Code)
	}
	return "parse_failed"
}

func parserHelp(err error) string {
	var parseError *taskparser.ParseError
	if errors.As(err, &parseError) {
		switch parseError.Code {
		case taskparser.ErrMultipleTimes, taskparser.ErrConflictingDates:
			return "Нашёл несколько дат или времён и не стал угадывать. Оставьте одно время, например: «Позвонить врачу завтра в 15:00»."
		case taskparser.ErrInvalidTime:
			return "Время должно быть от 00:00 до 23:59. Например: «Тренировка сегодня в 18:30»."
		case taskparser.ErrUnsupportedDateTime:
			return "Пока поддерживаются сегодня, завтра, послезавтра и точное время. Например: «Позвонить врачу завтра в 15:00»."
		case taskparser.ErrMissingTitle:
			return "Не нашёл название задачи. Например: «Купить молоко завтра в 18:00»."
		case taskparser.ErrInputTooLong:
			return "Команда слишком длинная. Сократите её до 4096 символов."
		}
	}
	return "Не понял команду. Например: «Позвонить врачу завтра в 15:00»."
}

func helpText() string {
	return "Отправьте задачу текстом или голосом.\n\nПримеры:\n• Купить молоко сегодня в 18:00\n• Позвонить врачу завтра в пятнадцать\n• Сдать отчёт до завтра"
}

func confirmationText(input string, draft taskparser.Draft, messageTime time.Time, location *time.Location, voice bool) string {
	var builder strings.Builder
	if voice {
		builder.WriteString("🎙 Распознано: «")
		builder.WriteString(truncateRunes(strings.TrimSpace(input), 1400))
		builder.WriteString("»\n")
	}
	builder.WriteString("✅ Создано: «")
	builder.WriteString(truncateRunes(draft.Title, 1400))
	builder.WriteString("» — ")
	builder.WriteString(formatMoment(draft, messageTime, location))
	if draft.PastExplicit {
		builder.WriteString("\n⚠️ Указанное время сегодня уже прошло.")
	}
	return builder.String()
}

func formatMoment(draft taskparser.Draft, messageTime time.Time, location *time.Location) string {
	moment := draft.Scheduled
	prefix := ""
	if draft.Due != nil {
		moment = draft.Due
		prefix = "срок: "
	}
	if moment == nil {
		return "Входящие"
	}
	localMoment := moment.In(location)
	messageDay := time.Date(messageTime.In(location).Year(), messageTime.In(location).Month(), messageTime.In(location).Day(), 0, 0, 0, 0, location)
	momentDay := time.Date(localMoment.Year(), localMoment.Month(), localMoment.Day(), 0, 0, 0, 0, location)
	dayLabel := localMoment.Format("02.01.2006")
	switch days := int(momentDay.Sub(messageDay).Hours() / 24); days {
	case 0:
		dayLabel = "сегодня"
	case 1:
		dayLabel = "завтра"
	case 2:
		dayLabel = "послезавтра"
	}
	if localMoment.Hour() == 0 && localMoment.Minute() == 0 {
		return prefix + dayLabel + ", весь день"
	}
	return fmt.Sprintf("%s%s, %02d:%02d", prefix, dayLabel, localMoment.Hour(), localMoment.Minute())
}
