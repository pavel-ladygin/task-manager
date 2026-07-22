package server

import "encoding/json"

type SyncItem struct {
	EntityType      string          `json:"entityType"`
	EntityID        string          `json:"entityID"`
	PayloadJSON     json.RawMessage `json:"payloadJSON,omitempty"`
	ClientUpdatedAt string          `json:"clientUpdatedAt"`
	ServerUpdatedAt string          `json:"serverUpdatedAt,omitempty"`
	DeletedAt       *string         `json:"deletedAt,omitempty"`
	Version         int64           `json:"version"`
	SourceDeviceID  string          `json:"sourceDeviceID"`
}

type PushRequest struct {
	DeviceID string     `json:"deviceID"`
	Items    []SyncItem `json:"items"`
}

type PushResponse struct {
	ServerCursor int64 `json:"serverCursor"`
	Accepted     int   `json:"accepted"`
	Ignored      int   `json:"ignored"`
}

type PullResponse struct {
	ServerCursor int64      `json:"serverCursor"`
	ServerTime   string     `json:"serverTime"`
	Items        []SyncItem `json:"items"`
}

type StatusResponse struct {
	ServerCursor int64  `json:"serverCursor"`
	ServerTime   string `json:"serverTime"`
}
