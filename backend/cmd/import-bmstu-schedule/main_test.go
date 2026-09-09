package main

import (
	"strings"
	"testing"
)

func TestParseICSConvertsWeeklyCourseAndTeacher(t *testing.T) {
	ics := strings.Join([]string{
		"BEGIN:VCALENDAR",
		"BEGIN:VEVENT",
		"UID:course-1",
		"SUMMARY:Тестовый курс",
		"DTSTART:20260907T053000Z",
		"DTEND:20260907T070000Z",
		"DESCRIPTION:Лекция",
		"LOCATION:ГУК\\, 514",
		"ATTENDEE;CN=\"Преподаватель\":mailto:test@example.org",
		"RRULE:FREQ=WEEKLY;UNTIL=20270105;INTERVAL=2",
		"END:VEVENT",
		"END:VCALENDAR",
	}, "\r\n")

	events, err := parseICS([]byte(ics))
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 {
		t.Fatalf("expected one event, got %d", len(events))
	}
	event := events[0]
	if event.Recurrence != "biweekly" || event.Attendee != "Преподаватель" {
		t.Fatalf("unexpected recurrence or attendee: %#v", event)
	}
	if event.Until == nil || event.Until.Hour() != 23 || event.Until.Minute() != 59 {
		t.Fatalf("date-only UNTIL must be inclusive, got %v", event.Until)
	}
	payload, _, err := payloadFor(event, "2026-09-09T08:00:00Z")
	if err != nil || !strings.Contains(payload, "Europe/Moscow") || !strings.Contains(payload, "Преподаватель") {
		t.Fatalf("unexpected payload %q, error %v", payload, err)
	}
}
