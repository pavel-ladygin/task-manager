package server

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"planner-sync/internal/store"
)

type Server struct {
	store *store.Store
	token string
	mux   *http.ServeMux
}

func New(syncStore *store.Store, token string) http.Handler {
	server := &Server{
		store: syncStore,
		token: token,
		mux:   http.NewServeMux(),
	}
	server.routes()
	return server
}

func (server *Server) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	server.mux.ServeHTTP(writer, request)
}

func (server *Server) routes() {
	server.mux.HandleFunc("GET /health", server.health)
	server.mux.HandleFunc("GET /v1/sync/status", server.withAuth(server.status))
	server.mux.HandleFunc("POST /v1/sync/push", server.withAuth(server.push))
	server.mux.HandleFunc("GET /v1/sync/pull", server.withAuth(server.pull))
	server.mux.HandleFunc("POST /v1/sync/bootstrap", server.withAuth(server.bootstrap))
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

	writeJSON(writer, http.StatusOK, StatusResponse{
		ServerCursor: cursor,
		ServerTime:   time.Now().UTC().Format(time.RFC3339Nano),
	})
}

func (server *Server) push(writer http.ResponseWriter, request *http.Request) {
	var payload PushRequest
	if err := readJSON(request, &payload); err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}

	accepted, ignored, cursor, err := server.store.Push(toStoreItems(payload.Items, payload.DeviceID))
	if err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}

	writeJSON(writer, http.StatusOK, PushResponse{
		ServerCursor: cursor,
		Accepted:     accepted,
		Ignored:      ignored,
	})
}

func (server *Server) bootstrap(writer http.ResponseWriter, request *http.Request) {
	var payload PushRequest
	if err := readJSON(request, &payload); err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}

	cursor, err := server.store.Bootstrap(toStoreItems(payload.Items, payload.DeviceID))
	if err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}

	writeJSON(writer, http.StatusOK, PushResponse{
		ServerCursor: cursor,
		Accepted:     len(payload.Items),
		Ignored:      0,
	})
}

func (server *Server) pull(writer http.ResponseWriter, request *http.Request) {
	cursor := int64(0)
	rawCursor := request.URL.Query().Get("cursor")
	if rawCursor != "" {
		parsedCursor, err := strconv.ParseInt(rawCursor, 10, 64)
		if err != nil || parsedCursor < 0 {
			writeError(writer, http.StatusBadRequest, errors.New("cursor must be a non-negative integer"))
			return
		}
		cursor = parsedCursor
	}

	items, serverCursor, err := server.store.Pull(cursor)
	if err != nil {
		writeError(writer, http.StatusInternalServerError, err)
		return
	}

	writeJSON(writer, http.StatusOK, PullResponse{
		ServerCursor: serverCursor,
		ServerTime:   time.Now().UTC().Format(time.RFC3339Nano),
		Items:        fromStoreItems(items),
	})
}

func (server *Server) withAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(writer http.ResponseWriter, request *http.Request) {
		header := request.Header.Get("Authorization")
		if header != "Bearer "+server.token {
			writeError(writer, http.StatusUnauthorized, errors.New("unauthorized"))
			return
		}
		next(writer, request)
	}
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

func toStoreItems(items []SyncItem, fallbackDeviceID string) []store.Item {
	result := make([]store.Item, 0, len(items))
	for _, item := range items {
		sourceDeviceID := item.SourceDeviceID
		if sourceDeviceID == "" {
			sourceDeviceID = fallbackDeviceID
		}
		payloadJSON := strings.TrimSpace(string(item.PayloadJSON))
		if payloadJSON == "" {
			payloadJSON = "null"
		}
		result = append(result, store.Item{
			EntityType:      item.EntityType,
			EntityID:        item.EntityID,
			PayloadJSON:     payloadJSON,
			ClientUpdatedAt: item.ClientUpdatedAt,
			DeletedAt:       item.DeletedAt,
			Version:         item.Version,
			SourceDeviceID:  sourceDeviceID,
		})
	}
	return result
}

func fromStoreItems(items []store.Item) []SyncItem {
	result := make([]SyncItem, 0, len(items))
	for _, item := range items {
		result = append(result, SyncItem{
			EntityType:      item.EntityType,
			EntityID:        item.EntityID,
			PayloadJSON:     json.RawMessage(item.PayloadJSON),
			ClientUpdatedAt: item.ClientUpdatedAt,
			ServerUpdatedAt: item.ServerUpdatedAt,
			DeletedAt:       item.DeletedAt,
			Version:         item.Version,
			SourceDeviceID:  item.SourceDeviceID,
		})
	}
	return result
}
