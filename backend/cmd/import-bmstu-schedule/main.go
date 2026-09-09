// import-bmstu-schedule imports one published BMSTU ICS feed into Planner's
// sync database. It intentionally uses Store.ApplyMutations instead of raw
// SQL, so every device receives the records through the regular change log.
package main

import (
	"bufio"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"

	"planner-sync/internal/store"
)

const defaultICSURL = "https://lks.bmstu.ru/lks-back/srv/v2/ics/8354c048-b8ff-11ed-a3ad-272ac9bbc1e7"

type sourceEvent struct {
	UID         string
	Title       string
	Description string
	Location    string
	Attendee    string
	Start       time.Time
	End         time.Time
	Recurrence  string
	Until       *time.Time
}

type calendarEventPayload struct {
	ID                 string  `json:"id"`
	Title              string  `json:"title"`
	Notes              string  `json:"notes"`
	Start              string  `json:"start"`
	End                string  `json:"end"`
	TimeZoneIdentifier string  `json:"timeZoneIdentifier"`
	RecurrenceRawValue string  `json:"recurrenceRawValue"`
	RecurrenceEndDate  *string `json:"recurrenceEndDate"`
	ProjectID          *string `json:"projectID"`
	ReminderRawValue   int     `json:"reminderRawValue"`
	CreatedAt          string  `json:"createdAt"`
	UpdatedAt          string  `json:"updatedAt"`
}

func main() {
	dbPath := env("PLANNER_DB_PATH", "/data/planner.db")
	icsURL := env("BMSTU_ICS_URL", defaultICSURL)

	feed, err := download(icsURL)
	if err != nil {
		fatal(err)
	}
	events, err := parseICS(feed)
	if err != nil {
		fatal(err)
	}
	if len(events) == 0 {
		fatal(fmt.Errorf("ICS feed contains no VEVENT entries"))
	}

	syncStore, err := store.Open(dbPath)
	if err != nil {
		fatal(fmt.Errorf("open sync database: %w", err))
	}
	defer syncStore.Close()

	now := time.Now().UTC().Format(time.RFC3339Nano)
	mutations := make([]store.Mutation, 0, len(events))
	for _, event := range events {
		payload, entityID, err := payloadFor(event, now)
		if err != nil {
			fatal(err)
		}
		mutations = append(mutations, store.Mutation{
			MutationID:     stableUUID("bmstu-import-mutation:" + event.UID),
			EntityType:     "calendarEvent",
			EntityID:       entityID,
			Operation:      "upsert",
			PayloadJSON:    payload,
			BaseRevision:   0,
			CreatedAt:      now,
			SourceDeviceID: "vps-import:bmstu",
		})
	}

	results, cursor, err := syncStore.ApplyMutations(mutations)
	if err != nil {
		fatal(fmt.Errorf("write schedule: %w", err))
	}
	created, duplicates, conflicts := 0, 0, 0
	for _, result := range results {
		switch result.Status {
		case "accepted":
			created++
		case "duplicate":
			duplicates++
		case "conflict":
			conflicts++
		}
	}
	if conflicts > 0 {
		fatal(fmt.Errorf("%d imported events conflict with existing data; no conflicting event was changed", conflicts))
	}
	fmt.Printf("BMSTU schedule: %d added, %d already present, server revision %d\n", created, duplicates, cursor)
}

func download(url string) ([]byte, error) {
	client := &http.Client{Timeout: 20 * time.Second}
	response, err := client.Get(url)
	if err != nil {
		return nil, fmt.Errorf("download ICS: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("download ICS: unexpected HTTP status %s", response.Status)
	}
	return io.ReadAll(io.LimitReader(response.Body, 2<<20))
}

func parseICS(data []byte) ([]sourceEvent, error) {
	lines := []string{}
	scanner := bufio.NewScanner(strings.NewReader(string(data)))
	scanner.Buffer(make([]byte, 1024), 1<<20)
	for scanner.Scan() {
		line := strings.TrimSuffix(scanner.Text(), "\r")
		if len(lines) > 0 && (strings.HasPrefix(line, " ") || strings.HasPrefix(line, "\t")) {
			lines[len(lines)-1] += strings.TrimLeft(line, " \t")
		} else {
			lines = append(lines, line)
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}

	var events []sourceEvent
	var current *sourceEvent
	for _, line := range lines {
		switch line {
		case "BEGIN:VEVENT":
			current = &sourceEvent{}
		case "END:VEVENT":
			if current != nil && current.UID != "" && current.Title != "" && !current.Start.IsZero() && !current.End.IsZero() {
				events = append(events, *current)
			}
			current = nil
		default:
			if current == nil {
				continue
			}
			key, value, ok := icsProperty(line)
			if !ok {
				continue
			}
			switch key {
			case "UID":
				current.UID = value
			case "SUMMARY":
				current.Title = unescapeICS(value)
			case "DESCRIPTION":
				current.Description = unescapeICS(value)
			case "LOCATION":
				current.Location = unescapeICS(value)
			case "ATTENDEE":
				current.Attendee = attendeeName(line)
				if current.Attendee == "" {
					current.Attendee = unescapeICS(value)
				}
			case "DTSTART":
				current.Start, _ = parseICSDate(value)
			case "DTEND":
				current.End, _ = parseICSDate(value)
			case "RRULE":
				current.Recurrence, current.Until = recurrence(value)
			}
		}
	}
	sort.Slice(events, func(i, j int) bool { return events[i].Start.Before(events[j].Start) })
	return events, nil
}

func icsProperty(line string) (string, string, bool) {
	parts := strings.SplitN(line, ":", 2)
	if len(parts) != 2 {
		return "", "", false
	}
	return strings.ToUpper(strings.SplitN(parts[0], ";", 2)[0]), parts[1], true
}

func attendeeName(line string) string {
	header := strings.SplitN(line, ":", 2)[0]
	for _, parameter := range strings.Split(header, ";")[1:] {
		pair := strings.SplitN(parameter, "=", 2)
		if len(pair) == 2 && strings.EqualFold(pair[0], "CN") {
			return unescapeICS(strings.Trim(pair[1], "\""))
		}
	}
	return ""
}

func parseICSDate(value string) (time.Time, error) {
	for _, layout := range []string{"20060102T150405Z", "20060102T1504Z", "20060102"} {
		if parsed, err := time.Parse(layout, value); err == nil {
			return parsed, nil
		}
	}
	return time.Time{}, fmt.Errorf("unsupported ICS date %q", value)
}

func recurrence(rule string) (string, *time.Time) {
	values := map[string]string{}
	for _, part := range strings.Split(rule, ";") {
		pair := strings.SplitN(part, "=", 2)
		if len(pair) == 2 {
			values[strings.ToUpper(pair[0])] = pair[1]
		}
	}
	if values["FREQ"] != "WEEKLY" {
		return "none", nil
	}
	frequency := "weekly"
	if values["INTERVAL"] == "2" {
		frequency = "biweekly"
	}
	var until *time.Time
	if raw := values["UNTIL"]; raw != "" {
		if date, err := parseICSDate(raw); err == nil {
			// Date-only UNTIL is inclusive under RFC 5545.
			if len(raw) == 8 {
				date = date.Add(24*time.Hour - time.Nanosecond)
			}
			until = &date
		}
	}
	return frequency, until
}

func payloadFor(event sourceEvent, now string) (string, string, error) {
	id := stableUUID("bmstu-calendar-event:" + event.UID)
	notes := make([]string, 0, 3)
	if event.Description != "" {
		notes = append(notes, event.Description)
	}
	if event.Location != "" {
		notes = append(notes, "Место: "+event.Location)
	}
	if event.Attendee != "" {
		notes = append(notes, "Преподаватель: "+event.Attendee)
	}
	var until *string
	if event.Until != nil {
		value := event.Until.UTC().Format(time.RFC3339Nano)
		until = &value
	}
	payload, err := json.Marshal(calendarEventPayload{
		ID: id, Title: event.Title, Notes: strings.Join(notes, "\n"),
		Start: event.Start.UTC().Format(time.RFC3339Nano), End: event.End.UTC().Format(time.RFC3339Nano),
		TimeZoneIdentifier: "Europe/Moscow", RecurrenceRawValue: event.Recurrence,
		RecurrenceEndDate: until, ProjectID: nil, ReminderRawValue: -1,
		CreatedAt: now, UpdatedAt: now,
	})
	return string(payload), id, err
}

func stableUUID(value string) string {
	sum := sha1.Sum([]byte(value))
	bytes := sum[:16]
	bytes[6] = (bytes[6] & 0x0f) | 0x50
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	hexValue := hex.EncodeToString(bytes)
	return fmt.Sprintf("%s-%s-%s-%s-%s", hexValue[:8], hexValue[8:12], hexValue[12:16], hexValue[16:20], hexValue[20:])
}

func unescapeICS(value string) string {
	value = strings.ReplaceAll(value, "\\n", "\n")
	value = strings.ReplaceAll(value, "\\N", "\n")
	value = strings.ReplaceAll(value, "\\,", ",")
	value = strings.ReplaceAll(value, "\\;", ";")
	return strings.ReplaceAll(value, "\\\\", "\\")
}

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "import-bmstu-schedule:", err)
	os.Exit(1)
}
