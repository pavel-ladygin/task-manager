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
	request := httptest.NewRequest(http.MethodGet, "/v2/sync/status", nil)

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", response.Code)
	}
}

func TestV1ProtocolIsUnavailable(t *testing.T) {
	handler := newTestServer(t)
	request := httptest.NewRequest(http.MethodGet, "/v1/sync/status", nil)
	request.Header.Set("Authorization", "Bearer secret")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusNotFound {
		t.Fatalf("expected v1 to be unavailable, got %d", response.Code)
	}
}

func TestV2InitializeIsSafeAndChangesAreIncremental(t *testing.T) {
	handler := newTestServer(t)
	now := time.Date(2026, 7, 10, 12, 0, 0, 0, time.UTC).Format(time.RFC3339Nano)

	initialize := map[string]any{
		"deviceID": "mac",
		"mutations": []map[string]any{
			{"mutationID": "initial-1", "entityType": "task", "entityID": "task-1", "operation": "upsert", "payload": map[string]any{"title": "Initial"}, "baseRevision": 0, "createdAt": now},
		},
	}
	doJSON(t, handler, http.MethodPost, "/v2/sync/initialize", "secret", initialize, http.StatusOK)
	doJSON(t, handler, http.MethodPost, "/v2/sync/initialize", "secret", initialize, http.StatusConflict)

	request := httptest.NewRequest(http.MethodGet, "/v2/sync/changes?after=0&limit=10", nil)
	request.Header.Set("Authorization", "Bearer secret")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)

	var pull struct {
		Items []struct {
			EntityID string `json:"entityID"`
		} `json:"changes"`
	}
	decode(t, response, &pull)
	if len(pull.Items) != 1 || pull.Items[0].EntityID != "task-1" {
		t.Fatalf("expected initialized item, got %+v", pull.Items)
	}
}

func TestV2MutationIsIdempotentAndDetectsConflict(t *testing.T) {
	handler := newTestServer(t)
	now := time.Date(2026, 7, 10, 12, 0, 0, 123456000, time.UTC).Format(time.RFC3339Nano)
	request := map[string]any{
		"deviceID": "mac",
		"mutations": []map[string]any{
			{"mutationID": "mutation-1", "entityType": "task", "entityID": "task-1", "operation": "upsert", "payload": map[string]any{"title": "Mac"}, "baseRevision": 0, "createdAt": now},
		},
	}
	doJSON(t, handler, http.MethodPost, "/v2/sync/initialize", "secret", request, http.StatusOK)
	response := doJSON(t, handler, http.MethodPost, "/v2/sync/mutations", "secret", request, http.StatusOK)
	var duplicate struct {
		Results []struct {
			Status string `json:"status"`
		} `json:"results"`
	}
	decode(t, response, &duplicate)
	if len(duplicate.Results) != 1 || duplicate.Results[0].Status != "duplicate" {
		t.Fatalf("expected duplicate result, got %+v", duplicate.Results)
	}

	conflicting := map[string]any{
		"deviceID": "phone",
		"mutations": []map[string]any{
			{"mutationID": "mutation-2", "entityType": "task", "entityID": "task-1", "operation": "upsert", "payload": map[string]any{"title": "Phone"}, "baseRevision": 0, "createdAt": now},
		},
	}
	response = doJSON(t, handler, http.MethodPost, "/v2/sync/mutations", "secret", conflicting, http.StatusOK)
	var conflict struct {
		Results []struct {
			Status  string `json:"status"`
			Current any    `json:"current"`
		} `json:"results"`
	}
	decode(t, response, &conflict)
	if len(conflict.Results) != 1 || conflict.Results[0].Status != "conflict" || conflict.Results[0].Current == nil {
		t.Fatalf("expected conflict with current state, got %+v", conflict.Results)
	}
}

func TestV2ChangesArePaginatedWithoutAdvancingPastAppliedPage(t *testing.T) {
	handler := newTestServer(t)
	now := time.Date(2026, 7, 10, 12, 0, 0, 123456000, time.UTC).Format(time.RFC3339Nano)
	mutations := make([]map[string]any, 0, 3)
	for index := 1; index <= 3; index++ {
		mutations = append(mutations, map[string]any{
			"mutationID":   "page-mutation-" + string(rune('0'+index)),
			"entityType":   "task",
			"entityID":     "page-task-" + string(rune('0'+index)),
			"operation":    "upsert",
			"payload":      map[string]any{"index": index},
			"baseRevision": 0,
			"createdAt":    now,
		})
	}
	doJSON(t, handler, http.MethodPost, "/v2/sync/initialize", "secret", map[string]any{
		"deviceID": "mac", "mutations": mutations,
	}, http.StatusOK)

	firstRequest := httptest.NewRequest(http.MethodGet, "/v2/sync/changes?after=0&limit=2", nil)
	firstRequest.Header.Set("Authorization", "Bearer secret")
	firstResponse := httptest.NewRecorder()
	handler.ServeHTTP(firstResponse, firstRequest)
	var first struct {
		HasMore bool `json:"hasMore"`
		Changes []struct {
			Revision int64 `json:"revision"`
		} `json:"changes"`
	}
	decode(t, firstResponse, &first)
	if !first.HasMore || len(first.Changes) != 2 {
		t.Fatalf("expected a full first page, got %+v", first)
	}

	secondRequest := httptest.NewRequest(http.MethodGet, "/v2/sync/changes?after=2&limit=2", nil)
	secondRequest.Header.Set("Authorization", "Bearer secret")
	secondResponse := httptest.NewRecorder()
	handler.ServeHTTP(secondResponse, secondRequest)
	var second struct {
		HasMore bool  `json:"hasMore"`
		Changes []any `json:"changes"`
	}
	decode(t, secondResponse, &second)
	if second.HasMore || len(second.Changes) != 1 {
		t.Fatalf("expected one final change, got %+v", second)
	}
}

func TestV2MutationsCannotInitializeEmptyServer(t *testing.T) {
	handler := newTestServer(t)
	now := time.Date(2026, 7, 10, 12, 0, 0, 0, time.UTC).Format(time.RFC3339Nano)
	request := map[string]any{
		"deviceID": "mac",
		"mutations": []map[string]any{
			{"mutationID": "forbidden-1", "entityType": "settings", "entityID": "app-settings", "operation": "upsert", "payload": map[string]any{"theme": "system"}, "baseRevision": 0, "createdAt": now},
		},
	}
	doJSON(t, handler, http.MethodPost, "/v2/sync/mutations", "secret", request, http.StatusBadRequest)

	statusRequest := httptest.NewRequest(http.MethodGet, "/v2/sync/status", nil)
	statusRequest.Header.Set("Authorization", "Bearer secret")
	statusResponse := httptest.NewRecorder()
	handler.ServeHTTP(statusResponse, statusRequest)
	var status struct {
		IsEmpty bool `json:"isEmpty"`
	}
	decode(t, statusResponse, &status)
	if !status.IsEmpty {
		t.Fatal("ordinary mutations must not initialize an empty server")
	}
}

func TestWidgetSnapshotUsesSeparateReadOnlyTokenAndMinimalPayload(t *testing.T) {
	handler := newTestServer(t)
	now := time.Date(2026, 7, 10, 12, 0, 0, 123456000, time.UTC).Format(time.RFC3339Nano)
	projectID := "00000000-0000-4000-8000-000000000010"
	doJSON(t, handler, http.MethodPost, "/v2/sync/initialize", "secret", map[string]any{
		"deviceID": "mac",
		"mutations": []map[string]any{
			{
				"mutationID": "widget-project", "entityType": "project", "entityID": projectID,
				"operation": "upsert", "baseRevision": 0, "createdAt": now,
				"payload": map[string]any{"id": projectID, "title": "Учёба", "color": "ocean", "notes": "private"},
			},
			{
				"mutationID": "widget-active", "entityType": "task", "entityID": "00000000-0000-4000-8000-000000000011",
				"operation": "upsert", "baseRevision": 0, "createdAt": now,
				"payload": map[string]any{
					"id": "00000000-0000-4000-8000-000000000011", "title": "Пара",
					"status": "planned", "priority": "high", "scheduled": now, "createdAt": now,
					"projectID": projectID, "notes": "must not leave server", "checklistItems": []any{},
				},
			},
			{
				"mutationID": "widget-done", "entityType": "task", "entityID": "00000000-0000-4000-8000-000000000012",
				"operation": "upsert", "baseRevision": 0, "createdAt": now,
				"payload": map[string]any{
					"id": "00000000-0000-4000-8000-000000000012", "title": "Готово",
					"status": "done", "priority": "none", "createdAt": now,
				},
			},
		},
	}, http.StatusOK)

	doJSON(t, handler, http.MethodGet, "/v2/widget/snapshot", "", nil, http.StatusUnauthorized)
	doJSON(t, handler, http.MethodGet, "/v2/widget/snapshot", "secret", nil, http.StatusUnauthorized)
	response := doJSON(t, handler, http.MethodGet, "/v2/widget/snapshot", "widget-secret", nil, http.StatusOK)

	var snapshot WidgetSnapshotTestResponse
	decode(t, response, &snapshot)
	if len(snapshot.Tasks) != 1 || snapshot.Tasks[0].Title != "Пара" {
		t.Fatalf("expected one active widget task, got %+v", snapshot.Tasks)
	}
	if len(snapshot.Projects) != 1 || snapshot.Projects[0].Title != "Учёба" {
		t.Fatalf("expected project metadata, got %+v", snapshot.Projects)
	}
	if bytes.Contains(response.Body.Bytes(), []byte("must not leave server")) ||
		bytes.Contains(response.Body.Bytes(), []byte("checklistItems")) {
		t.Fatal("widget endpoint exposed fields outside the minimal read-only projection")
	}

	doJSON(t, handler, http.MethodPost, "/v2/sync/mutations", "widget-secret", map[string]any{
		"deviceID": "widget", "mutations": []any{},
	}, http.StatusUnauthorized)
}

type WidgetSnapshotTestResponse struct {
	Tasks []struct {
		Title string `json:"title"`
	} `json:"tasks"`
	Projects []struct {
		Title string `json:"title"`
	} `json:"projects"`
}

func newTestServer(t *testing.T) http.Handler {
	t.Helper()
	syncStore, err := store.Open(filepath.Join(t.TempDir(), "planner.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = syncStore.Close() })
	return server.New(syncStore, "secret", "widget-secret")
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
