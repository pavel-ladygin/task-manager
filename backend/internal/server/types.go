package server

import "encoding/json"

type StatusResponse struct {
	ServerCursor    int64  `json:"serverCursor"`
	ServerTime      string `json:"serverTime"`
	ProtocolVersion int    `json:"protocolVersion"`
	IsEmpty         bool   `json:"isEmpty"`
}

type Mutation struct {
	MutationID   string          `json:"mutationID"`
	EntityType   string          `json:"entityType"`
	EntityID     string          `json:"entityID"`
	Operation    string          `json:"operation"`
	Payload      json.RawMessage `json:"payload,omitempty"`
	BaseRevision int64           `json:"baseRevision"`
	CreatedAt    string          `json:"createdAt"`
}

type MutationRequest struct {
	DeviceID  string     `json:"deviceID"`
	Mutations []Mutation `json:"mutations"`
}

type ServerChange struct {
	Revision        int64           `json:"revision"`
	EntityType      string          `json:"entityType"`
	EntityID        string          `json:"entityID"`
	Operation       string          `json:"operation"`
	Payload         json.RawMessage `json:"payload,omitempty"`
	SourceDeviceID  string          `json:"sourceDeviceID"`
	ServerUpdatedAt string          `json:"serverUpdatedAt"`
}

type MutationResult struct {
	MutationID     string        `json:"mutationID"`
	Status         string        `json:"status"`
	ServerRevision int64         `json:"serverRevision"`
	Current        *ServerChange `json:"current,omitempty"`
}

type MutationResponse struct {
	ServerCursor int64            `json:"serverCursor"`
	Results      []MutationResult `json:"results"`
}

type ChangesResponse struct {
	ServerCursor int64          `json:"serverCursor"`
	HasMore      bool           `json:"hasMore"`
	Changes      []ServerChange `json:"changes"`
}

type WidgetSnapshotResponse struct {
	ServerCursor int64           `json:"serverCursor"`
	GeneratedAt  string          `json:"generatedAt"`
	Tasks        []WidgetTask    `json:"tasks"`
	Projects     []WidgetProject `json:"projects"`
}

type WidgetTask struct {
	ID        string  `json:"id"`
	Title     string  `json:"title"`
	Status    string  `json:"status"`
	Priority  string  `json:"priority"`
	Scheduled *string `json:"scheduled,omitempty"`
	Due       *string `json:"due,omitempty"`
	CreatedAt string  `json:"createdAt"`
	ProjectID *string `json:"projectID,omitempty"`
}

type WidgetProject struct {
	ID    string  `json:"id"`
	Title string  `json:"title"`
	Color *string `json:"color,omitempty"`
}
