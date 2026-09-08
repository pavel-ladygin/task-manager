package telegrambot

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"planner-sync/internal/store"
)

const (
	maximumWebhookBytes = 256 << 10
	maximumVoiceBytes   = 1 << 20
	maximumVoiceSeconds = 30
)

type updateQueue interface {
	EnqueueTelegramUpdate(context.Context, store.TelegramUpdate, time.Time) (bool, error)
}

type Handler struct {
	queue         updateQueue
	botID         string
	secret        string
	allowedUserID int64
	notify        func()
	now           func() time.Time
	newTaskID     func() (string, error)
}

func NewHandler(queue updateQueue, botID string, secret string, allowedUserID int64, notify func()) http.Handler {
	return &Handler{
		queue: queue, botID: botID, secret: secret, allowedUserID: allowedUserID,
		notify: notify, now: time.Now, newTaskID: uuidV4,
	}
}

func (handler *Handler) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	if !constantTimeEqual(request.Header.Get("X-Telegram-Bot-Api-Secret-Token"), handler.secret) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	defer request.Body.Close()
	var update Update
	decoder := json.NewDecoder(http.MaxBytesReader(writer, request.Body, maximumWebhookBytes))
	if err := decoder.Decode(&update); err != nil {
		http.Error(writer, "invalid update", http.StatusBadRequest)
		return
	}
	if err := ensureJSONEnd(decoder); err != nil || update.UpdateID <= 0 || update.Message == nil || update.Message.Date <= 0 {
		http.Error(writer, "invalid update", http.StatusBadRequest)
		return
	}
	message := update.Message
	if message.From == nil || message.From.ID != handler.allowedUserID || message.Chat.Type != "private" || message.Chat.ID != handler.allowedUserID {
		writer.WriteHeader(http.StatusOK)
		return
	}
	taskID, err := handler.newTaskID()
	if err != nil {
		http.Error(writer, "temporary failure", http.StatusServiceUnavailable)
		return
	}
	kind, payload := classifyMessage(message)
	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		http.Error(writer, "temporary failure", http.StatusServiceUnavailable)
		return
	}
	now := handler.now()
	inserted, err := handler.queue.EnqueueTelegramUpdate(request.Context(), store.TelegramUpdate{
		BotID: handler.botID, UpdateID: update.UpdateID, ChatID: message.Chat.ID,
		MessageDate: message.Date, Kind: kind, PayloadJSON: string(payloadJSON), TaskID: taskID,
	}, now)
	if err != nil {
		http.Error(writer, "temporary failure", http.StatusServiceUnavailable)
		return
	}
	if inserted && handler.notify != nil {
		handler.notify()
	}
	writer.WriteHeader(http.StatusOK)
}

func classifyMessage(message *Message) (string, queuedPayload) {
	if message.Voice != nil {
		voice := message.Voice
		if voice.FileID == "" || voice.Duration <= 0 {
			return "unsupported", queuedPayload{Reason: "invalid_voice"}
		}
		if voice.Duration > maximumVoiceSeconds || voice.FileSize > maximumVoiceBytes {
			return "unsupported", queuedPayload{Reason: "voice_too_large"}
		}
		return "voice", queuedPayload{FileID: voice.FileID, FileSize: voice.FileSize, Duration: voice.Duration}
	}
	text := strings.TrimSpace(message.Text)
	if text != "" {
		command := strings.ToLower(strings.Fields(text)[0])
		if at := strings.IndexByte(command, '@'); at >= 0 {
			command = command[:at]
		}
		if command == "/start" || command == "/help" {
			return "help", queuedPayload{}
		}
		return "text", queuedPayload{Text: text}
	}
	return "unsupported", queuedPayload{Reason: "unsupported_message"}
}

func constantTimeEqual(provided string, expected string) bool {
	if provided == "" || expected == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(provided), []byte(expected)) == 1
}

func ensureJSONEnd(decoder *json.Decoder) error {
	var extra any
	err := decoder.Decode(&extra)
	if errors.Is(err, io.EOF) {
		return nil
	}
	if err == nil {
		return errors.New("multiple JSON values")
	}
	return err
}

func uuidV4() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	value[6] = (value[6] & 0x0f) | 0x40
	value[8] = (value[8] & 0x3f) | 0x80
	encoded := make([]byte, 36)
	hex.Encode(encoded[0:8], value[0:4])
	encoded[8] = '-'
	hex.Encode(encoded[9:13], value[4:6])
	encoded[13] = '-'
	hex.Encode(encoded[14:18], value[6:8])
	encoded[18] = '-'
	hex.Encode(encoded[19:23], value[8:10])
	encoded[23] = '-'
	hex.Encode(encoded[24:36], value[10:16])
	return string(encoded), nil
}
