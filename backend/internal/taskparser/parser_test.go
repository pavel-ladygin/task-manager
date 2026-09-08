package taskparser

import (
	"testing"
	"time"
)

func TestParseSupportedCommands(t *testing.T) {
	location := mustMoscow(t)
	now := time.Date(2026, 9, 7, 17, 30, 20, 0, location)
	tests := []struct {
		name      string
		input     string
		title     string
		scheduled string
		due       string
		status    string
		past      bool
	}{
		{"today", "сходить посрать в 18:00 сегодня", "Сходить посрать", "2026-09-07T18:00:00+03:00", "", "planned", false},
		{"tomorrow", "позвонить врачу 15:00 завтра", "Позвонить врачу", "2026-09-08T15:00:00+03:00", "", "planned", false},
		{"due", "сдать отчёт до 18:00 завтра", "Сдать отчёт", "", "2026-09-08T18:00:00+03:00", "planned", false},
		{"date due", "подготовить релиз к послезавтра в 9", "Подготовить релиз", "", "2026-09-09T09:00:00+03:00", "planned", false},
		{"due wins", "сделать до завтра в 18", "Сделать", "", "2026-09-08T18:00:00+03:00", "planned", false},
		{"all day", "тренировка послезавтра", "Тренировка", "2026-09-09T00:00:00+03:00", "", "planned", false},
		{"all day due", "сдать отчёт до завтра", "Сдать отчёт", "", "2026-09-08T00:00:00+03:00", "planned", false},
		{"inbox", "купить молоко", "Купить молоко", "", "", "inbox", false},
		{"implicit today", "звонок в 18", "Звонок", "2026-09-07T18:00:00+03:00", "", "planned", false},
		{"implicit tomorrow", "звонок в 17", "Звонок", "2026-09-08T17:00:00+03:00", "", "planned", false},
		{"explicit past", "звонок сегодня в 17", "Звонок", "2026-09-07T17:00:00+03:00", "", "planned", true},
		{"words", "напомни мне позвонить маме завтра в восемнадцать ноль ноль", "Позвонить маме", "2026-09-08T18:00:00+03:00", "", "planned", false},
		{"evening", "встреча завтра в шесть вечера", "Встреча", "2026-09-08T18:00:00+03:00", "", "planned", false},
		{"afternoon", "встреча завтра в два дня", "Встреча", "2026-09-08T14:00:00+03:00", "", "planned", false},
		{"midnight", "релиз завтра в двенадцать ночи", "Релиз", "2026-09-08T00:00:00+03:00", "", "planned", false},
		{"word 24h", "встреча завтра в шесть", "Встреча", "2026-09-08T06:00:00+03:00", "", "planned", false},
		{"dot", "созвон в 18.30", "Созвон", "2026-09-07T18:30:00+03:00", "", "planned", false},
		{"space", "созвон завтра в 18 30", "Созвон", "2026-09-08T18:30:00+03:00", "", "planned", false},
		{"scheduled marker", "тренировка на завтра", "Тренировка", "2026-09-08T00:00:00+03:00", "", "planned", false},
		{"number title", "купить 18 яиц завтра", "Купить 18 яиц", "2026-09-08T00:00:00+03:00", "", "planned", false},
		{"not due", "позвонить к врачу завтра в 15", "Позвонить к врачу", "2026-09-08T15:00:00+03:00", "", "planned", false},
		{"literal through", "пройти через парк", "Пройти через парк", "", "", "inbox", false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			draft, err := Parse(test.input, now, location)
			if err != nil {
				t.Fatalf("Parse() error = %v", err)
			}
			if draft.Title != test.title || draft.Status != test.status || draft.PastExplicit != test.past {
				t.Fatalf("unexpected draft: %+v", draft)
			}
			if formatTime(draft.Scheduled) != test.scheduled || formatTime(draft.Due) != test.due {
				t.Fatalf("unexpected dates: scheduled=%s due=%s", formatTime(draft.Scheduled), formatTime(draft.Due))
			}
			if draft.Priority != "none" {
				t.Fatalf("unexpected priority: %s", draft.Priority)
			}
		})
	}
}

func TestParseErrors(t *testing.T) {
	location := mustMoscow(t)
	now := time.Date(2026, 9, 7, 17, 30, 20, 0, location)
	tests := []struct {
		input string
		code  ErrorCode
	}{
		{"", ErrEmptyInput},
		{"встреча завтра в 25:00", ErrInvalidTime},
		{"встреча завтра в 25", ErrInvalidTime},
		{"встреча завтра в 18 90", ErrInvalidTime},
		{"встреча завтра в 18 или в 19", ErrMultipleTimes},
		{"встреча сегодня завтра в 18", ErrConflictingDates},
		{"встретиться в пятницу", ErrUnsupportedDateTime},
		{"встретиться завтра вечером", ErrUnsupportedDateTime},
		{"подготовить отчёт 10.09", ErrUnsupportedDateTime},
		{"сегодня в 18", ErrMissingTitle},
		{"позвонить через два часа", ErrUnsupportedDateTime},
		{"встретиться без десяти шесть", ErrUnsupportedDateTime},
	}
	for _, test := range tests {
		t.Run(test.input, func(t *testing.T) {
			_, err := Parse(test.input, now, location)
			if !IsCode(err, test.code) {
				t.Fatalf("Parse() error = %v, want %s", err, test.code)
			}
		})
	}
}

func TestCurrentMinuteStaysToday(t *testing.T) {
	location := mustMoscow(t)
	now := time.Date(2026, 9, 7, 18, 0, 59, 0, location)
	draft, err := Parse("созвон в 18:00", now, location)
	if err != nil {
		t.Fatal(err)
	}
	if got := formatTime(draft.Scheduled); got != "2026-09-07T18:00:00+03:00" {
		t.Fatalf("scheduled = %s", got)
	}
}

func FuzzParseNeverPanics(f *testing.F) {
	f.Add("сходить посрать в 18:00 сегодня")
	f.Add("завтра в шесть вечера")
	location, _ := time.LoadLocation("Europe/Moscow")
	now := time.Date(2026, 9, 7, 17, 30, 20, 0, location)
	f.Fuzz(func(t *testing.T, input string) {
		draft, err := Parse(input, now, location)
		if err == nil {
			if draft.Title == "" {
				t.Fatal("successful parse returned an empty title")
			}
			if draft.Scheduled != nil && draft.Due != nil {
				t.Fatal("successful parse returned scheduled and due")
			}
		}
	})
}

func mustMoscow(t *testing.T) *time.Location {
	t.Helper()
	location, err := time.LoadLocation("Europe/Moscow")
	if err != nil {
		t.Fatal(err)
	}
	return location
}

func formatTime(value *time.Time) string {
	if value == nil {
		return ""
	}
	return value.Format(time.RFC3339)
}
