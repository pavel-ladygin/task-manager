package server_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"planner-sync/internal/server"
	"planner-sync/internal/store"
)

func TestAuthRequired(t *testing.T) {
	handler := newTestServer(t)
	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/v1/sync/status", nil)

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", response.Code)
	}
}

func TestPushPullAndConflict(t *testing.T) {
	handler := newTestServer(t)
	firstTime := time.Date(2026, 7, 10, 12, 0, 0, 0, time.UTC).Format(time.RFC3339Nano)
	secondTime := time.Date(2026, 7, 10, 13, 0, 0, 0, time.UTC).Format(time.RFC3339Nano)

	push := map[string]any{
		"deviceID": "mac",
		"items": []map[string]any{
			{
				"entityType":      "task",
				"entityID":        "task-1",
				"payloadJSON":     map[string]any{"title": "First"},
				"clientUpdatedAt": firstTime,
				"version":         1,
				"sourceDeviceID":  "mac",
			},
		},
	}
	doJSON(t, handler, http.MethodPost, "/v1/sync/push", "secret", push, http.StatusOK)

	olderPush := map[string]any{
		"deviceID": "phone",
		"items": []map[string]any{
			{
				"entityType":      "task",
				"entityID":        "task-1",
				"payloadJSON":     map[string]any{"title": "Older"},
				"clientUpdatedAt": firstTime,
				"version":         0,
				"sourceDeviceID":  "phone",
			},
		},
	}
	response := doJSON(t, handler, http.MethodPost, "/v1/sync/push", "secret", olderPush, http.StatusOK)
	var pushResponse struct {
		Accepted int `json:"accepted"`
		Ignored  int `json:"ignored"`
	}
	decode(t, response, &pushResponse)
	if pushResponse.Accepted != 0 || pushResponse.Ignored != 1 {
		t.Fatalf("unexpected conflict response: %+v", pushResponse)
	}

	deleteTime := secondTime
	tombstone := map[string]any{
		"deviceID": "phone",
		"items": []map[string]any{
			{
				"entityType":      "task",
				"entityID":        "task-1",
				"payloadJSON":     nil,
				"clientUpdatedAt": deleteTime,
				"deletedAt":       deleteTime,
				"version":         1,
				"sourceDeviceID":  "phone",
			},
		},
	}
	doJSON(t, handler, http.MethodPost, "/v1/sync/push", "secret", tombstone, http.StatusOK)

	pullRequest := httptest.NewRequest(http.MethodGet, "/v1/sync/pull?cursor=0", nil)
	pullRequest.Header.Set("Authorization", "Bearer secret")
	pullResponse := httptest.NewRecorder()
	handler.ServeHTTP(pullResponse, pullRequest)
	if pullResponse.Code != http.StatusOK {
		t.Fatalf("pull status %d: %s", pullResponse.Code, pullResponse.Body.String())
	}

	var pull struct {
		Items []struct {
			EntityID  string  `json:"entityID"`
			DeletedAt *string `json:"deletedAt"`
		} `json:"items"`
	}
	decode(t, pullResponse, &pull)
	if len(pull.Items) != 1 || pull.Items[0].DeletedAt == nil {
		t.Fatalf("expected latest tombstone only, got %+v", pull.Items)
	}
}

func TestBootstrapReplacesStore(t *testing.T) {
	handler := newTestServer(t)
	now := time.Date(2026, 7, 10, 12, 0, 0, 0, time.UTC).Format(time.RFC3339Nano)

	push := map[string]any{
		"deviceID": "mac",
		"items": []map[string]any{
			{"entityType": "task", "entityID": "old", "payloadJSON": map[string]any{"title": "Old"}, "clientUpdatedAt": now, "version": 1, "sourceDeviceID": "mac"},
		},
	}
	doJSON(t, handler, http.MethodPost, "/v1/sync/push", "secret", push, http.StatusOK)

	bootstrap := map[string]any{
		"deviceID": "mac",
		"items": []map[string]any{
			{"entityType": "task", "entityID": "new", "payloadJSON": map[string]any{"title": "New"}, "clientUpdatedAt": now, "version": 1, "sourceDeviceID": "mac"},
		},
	}
	doJSON(t, handler, http.MethodPost, "/v1/sync/bootstrap", "secret", bootstrap, http.StatusOK)

	request := httptest.NewRequest(http.MethodGet, "/v1/sync/pull?cursor=0", nil)
	request.Header.Set("Authorization", "Bearer secret")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)

	var pull struct {
		Items []struct {
			EntityID string `json:"entityID"`
		} `json:"items"`
	}
	decode(t, response, &pull)
	if len(pull.Items) != 1 || pull.Items[0].EntityID != "new" {
		t.Fatalf("expected only bootstrapped item, got %+v", pull.Items)
	}
}

func newTestServer(t *testing.T) http.Handler {
	t.Helper()
	syncStore, err := store.Open(filepath.Join(t.TempDir(), "planner.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = syncStore.Close() })
	return server.New(syncStore, "secret")
}

func doJSON(t *testing.T, handler http.Handler, method string, path string, token string, payload any, expectedStatus int) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(method, path, bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != expectedStatus {
		t.Fatalf("expected %d, got %d: %s", expectedStatus, response.Code, response.Body.String())
	}
	return response
}

func decode(t *testing.T, response *httptest.ResponseRecorder, out any) {
	t.Helper()
	if err := json.Unmarshal(response.Body.Bytes(), out); err != nil {
		t.Fatalf("decode %s: %v", response.Body.String(), err)
	}
}
