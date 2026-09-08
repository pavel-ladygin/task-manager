package telegrambot

type Update struct {
	UpdateID int64    `json:"update_id"`
	Message  *Message `json:"message,omitempty"`
}

type Message struct {
	MessageID int64  `json:"message_id"`
	Date      int64  `json:"date"`
	Chat      Chat   `json:"chat"`
	From      *User  `json:"from,omitempty"`
	Text      string `json:"text,omitempty"`
	Voice     *Voice `json:"voice,omitempty"`
}

type Chat struct {
	ID   int64  `json:"id"`
	Type string `json:"type"`
}

type User struct {
	ID int64 `json:"id"`
}

type Voice struct {
	FileID   string `json:"file_id"`
	Duration int    `json:"duration"`
	FileSize int64  `json:"file_size,omitempty"`
}

type queuedPayload struct {
	Text     string `json:"text,omitempty"`
	FileID   string `json:"fileID,omitempty"`
	FileSize int64  `json:"fileSize,omitempty"`
	Duration int    `json:"duration,omitempty"`
	Reason   string `json:"reason,omitempty"`
}
