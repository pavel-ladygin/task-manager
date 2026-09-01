package server

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"planner-sync/internal/store"
)

type Server struct {
	store       *store.Store
	token       string
	widgetToken string
	mux         *http.ServeMux
}

func New(syncStore *store.Store, token string, widgetToken string) http.Handler {
	server := &Server{
		store:       syncStore,
		token:       token,
		widgetToken: widgetToken,
		mux:         http.NewServeMux(),
	}
	server.routes()
	return server
}

func (server *Server) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	server.mux.ServeHTTP(writer, request)
}

func (server *Server) routes() {
	server.mux.HandleFunc("GET /health", server.health)
	server.mux.HandleFunc("GET /v2/sync/status", server.withAuth(server.status))
	server.mux.HandleFunc("POST /v2/sync/initialize", server.withAuth(server.initialize))
	server.mux.HandleFunc("GET /v2/sync/changes", server.withAuth(server.changes))
	server.mux.HandleFunc("POST /v2/sync/mutations", server.withAuth(server.mutations))
	server.mux.HandleFunc("GET /v2/widget/snapshot", server.withWidgetAuth(server.widgetSnapshot))
}

func (server *Server) health(writer http.ResponseWriter, _ *http.Request) {
	writeJSON(writer, http.StatusOK, map[string]string{"status": "ok"})
}

func (server *Server) status(writer http.ResponseWriter, _ *http.Request) {
	cursor, err := server.store.Cursor()
	if err != nil {
		writeError(writer, http.StatusInternalServerError, err)
		return
	}

	isEmpty, err := server.store.IsEmpty()
	if err != nil {
		writeError(writer, http.StatusInternalServerError, err)
		return
	}
	writeJSON(writer, http.StatusOK, StatusResponse{
		ServerCursor:    cursor,
		ServerTime:      time.Now().UTC().Format(time.RFC3339Nano),
		ProtocolVersion: 2,
		IsEmpty:         isEmpty,
	})
}

func (server *Server) initialize(writer http.ResponseWriter, request *http.Request) {
	var payload MutationRequest
	if err := readJSON(request, &payload); err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}
	results, cursor, err := server.store.Initialize(toStoreMutations(payload))
	if err != nil {
		if strings.Contains(err.Error(), "already initialized") {
			writeError(writer, http.StatusConflict, err)
		} else {
			writeError(writer, http.StatusBadRequest, err)
		}
		return
	}
	writeJSON(writer, http.StatusOK, MutationResponse{ServerCursor: cursor, Results: fromMutationResults(results)})
}

func (server *Server) mutations(writer http.ResponseWriter, request *http.Request) {
	var payload MutationRequest
	if err := readJSON(request, &payload); err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}
	results, cursor, err := server.store.ApplyMutations(toStoreMutations(payload))
	if err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}
	writeJSON(writer, http.StatusOK, MutationResponse{ServerCursor: cursor, Results: fromMutationResults(results)})
}

func (server *Server) changes(writer http.ResponseWriter, request *http.Request) {
	after := int64(0)
	if raw := request.URL.Query().Get("after"); raw != "" {
		parsed, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || parsed < 0 {
			writeError(writer, http.StatusBadRequest, errors.New("after must be non-negative"))
			return
		}
		after = parsed
	}
	limit := 200
	if raw := request.URL.Query().Get("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 || parsed > 500 {
			writeError(writer, http.StatusBadRequest, errors.New("limit must be between 1 and 500"))
			return
		}
		limit = parsed
	}
	items, cursor, hasMore, err := server.store.Changes(after, limit)
	if err != nil {
		writeError(writer, http.StatusInternalServerError, err)
		return
	}
	writeJSON(writer, http.StatusOK, ChangesResponse{ServerCursor: cursor, HasMore: hasMore, Changes: fromChanges(items)})
}

func (server *Server) widgetSnapshot(writer http.ResponseWriter, _ *http.Request) {
	heads, cursor, err := server.store.WidgetHeads()
	if err != nil {
		writeError(writer, http.StatusInternalServerError, err)
		return
	}

	response := WidgetSnapshotResponse{
		ServerCursor: cursor,
		GeneratedAt:  time.Now().UTC().Format(time.RFC3339Nano),
		Tasks:        []WidgetTask{},
		Projects:     []WidgetProject{},
	}
	for _, head := range heads {
		switch head.EntityType {
		case "task":
			var task WidgetTask
			if err := json.Unmarshal([]byte(head.PayloadJSON), &task); err != nil {
				writeError(writer, http.StatusInternalServerError, errors.New("invalid task payload in store"))
				return
			}
			if task.Status == "done" || task.Status == "cancelled" {
				continue
			}
			response.Tasks = append(response.Tasks, task)
		case "project":
			var project WidgetProject
			if err := json.Unmarshal([]byte(head.PayloadJSON), &project); err != nil {
				writeError(writer, http.StatusInternalServerError, errors.New("invalid project payload in store"))
				return
			}
			response.Projects = append(response.Projects, project)
		}
	}
	writeJSON(writer, http.StatusOK, response)
}

func (server *Server) withAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(writer http.ResponseWriter, request *http.Request) {
		if !hasBearerToken(request, server.token) {
			writeError(writer, http.StatusUnauthorized, errors.New("unauthorized"))
			return
		}
		next(writer, request)
	}
}

func (server *Server) withWidgetAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(writer http.ResponseWriter, request *http.Request) {
		if !hasBearerToken(request, server.widgetToken) {
			writeError(writer, http.StatusUnauthorized, errors.New("unauthorized"))
			return
		}
		next(writer, request)
	}
}

func hasBearerToken(request *http.Request, expected string) bool {
	const prefix = "Bearer "
	header := request.Header.Get("Authorization")
	if expected == "" || !strings.HasPrefix(header, prefix) {
		return false
	}
	provided := strings.TrimPrefix(header, prefix)
	return subtle.ConstantTimeCompare([]byte(provided), []byte(expected)) == 1
}

func readJSON(request *http.Request, out any) error {
	defer request.Body.Close()
	decoder := json.NewDecoder(http.MaxBytesReader(nil, request.Body, 10<<20))
	decoder.DisallowUnknownFields()
	return decoder.Decode(out)
}

func writeJSON(writer http.ResponseWriter, status int, value any) {
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.WriteHeader(status)
	_ = json.NewEncoder(writer).Encode(value)
}

func writeError(writer http.ResponseWriter, status int, err error) {
	writeJSON(writer, status, map[string]string{"error": err.Error()})
}

func toStoreMutations(request MutationRequest) []store.Mutation {
	result := make([]store.Mutation, 0, len(request.Mutations))
	for _, mutation := range request.Mutations {
		payload := strings.TrimSpace(string(mutation.Payload))
		if payload == "" {
			payload = "null"
		}
		result = append(result, store.Mutation{
			MutationID:     mutation.MutationID,
			EntityType:     mutation.EntityType,
			EntityID:       mutation.EntityID,
			Operation:      mutation.Operation,
			PayloadJSON:    payload,
			BaseRevision:   mutation.BaseRevision,
			CreatedAt:      mutation.CreatedAt,
			SourceDeviceID: request.DeviceID,
		})
	}
	return result
}

func fromChanges(changes []store.Change) []ServerChange {
	result := make([]ServerChange, 0, len(changes))
	for _, change := range changes {
		result = append(result, ServerChange{
			Revision:        change.Revision,
			EntityType:      change.EntityType,
			EntityID:        change.EntityID,
			Operation:       change.Operation,
			Payload:         json.RawMessage(change.PayloadJSON),
			SourceDeviceID:  change.SourceDeviceID,
			ServerUpdatedAt: change.ServerUpdatedAt,
		})
	}
	return result
}

func fromMutationResults(results []store.MutationResult) []MutationResult {
	output := make([]MutationResult, 0, len(results))
	for _, result := range results {
		var current *ServerChange
		if result.Current != nil {
			mapped := fromChanges([]store.Change{*result.Current})[0]
			current = &mapped
		}
		output = append(output, MutationResult{
			MutationID:     result.MutationID,
			Status:         result.Status,
			ServerRevision: result.ServerRevision,
			Current:        current,
		})
	}
	return output
}
