package taskparser

import (
	"errors"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

type Draft struct {
	Title        string
	Status       string
	Priority     string
	Scheduled    *time.Time
	Due          *time.Time
	PastExplicit bool
}

type ErrorCode string

const (
	ErrEmptyInput          ErrorCode = "empty_input"
	ErrInputTooLong        ErrorCode = "input_too_long"
	ErrInvalidTime         ErrorCode = "invalid_time"
	ErrMultipleTimes       ErrorCode = "multiple_times"
	ErrConflictingDates    ErrorCode = "conflicting_dates"
	ErrUnsupportedDateTime ErrorCode = "unsupported_datetime"
	ErrMissingTitle        ErrorCode = "missing_title"
)

type ParseError struct {
	Code ErrorCode
}

func (err *ParseError) Error() string { return string(err.Code) }

func IsCode(err error, code ErrorCode) bool {
	var parseError *ParseError
	return errors.As(err, &parseError) && parseError.Code == code
}

const maxInputRunes = 4096

type tokenKind uint8

const (
	wordToken tokenKind = iota
	numberToken
	punctuationToken
)

type token struct {
	raw        string
	normalized string
	start      int
	end        int
	kind       tokenKind
}

type span struct {
	start int
	end   int
}

type dateMatch struct {
	offset int
	span   span
	due    bool
}

type timeMatch struct {
	hour   int
	minute int
	span   span
	due    bool
}

var calendarDatePattern = regexp.MustCompile(`(?:^|[^0-9])\d{1,2}[./]\d{1,2}(?:[./]\d{2,4})?(?:$|[^0-9])`)

func Parse(input string, now time.Time, location *time.Location) (Draft, error) {
	if location == nil {
		location = time.UTC
	}
	if strings.TrimSpace(input) == "" {
		return Draft{}, &ParseError{Code: ErrEmptyInput}
	}
	if utf8.RuneCountInString(input) > maxInputRunes {
		return Draft{}, &ParseError{Code: ErrInputTooLong}
	}

	tokens := tokenize(input)
	removals := make([]span, 0, 6)
	if prefix, ok := commandPrefix(tokens); ok {
		removals = append(removals, prefix)
	}

	dates := findDates(tokens)
	dateOffset := 0
	explicitDate := len(dates) > 0
	if explicitDate {
		dateOffset = dates[0].offset
		for _, match := range dates[1:] {
			if match.offset != dateOffset {
				return Draft{}, &ParseError{Code: ErrConflictingDates}
			}
		}
		for _, match := range dates {
			removals = append(removals, match.span)
		}
	}

	times, invalidTime := findTimes(tokens, explicitDate)
	if invalidTime {
		return Draft{}, &ParseError{Code: ErrInvalidTime}
	}
	if len(times) > 1 {
		return Draft{}, &ParseError{Code: ErrMultipleTimes}
	}
	if len(times) == 1 {
		removals = append(removals, times[0].span)
	}

	if hasUnsupportedDateTime(input, tokens, removals) {
		return Draft{}, &ParseError{Code: ErrUnsupportedDateTime}
	}

	title := titleWithoutSpans(input, removals)
	if title == "" {
		return Draft{}, &ParseError{Code: ErrMissingTitle}
	}

	draft := Draft{Title: title, Status: "inbox", Priority: "none"}
	if !explicitDate && len(times) == 0 {
		return draft, nil
	}

	localNow := now.In(location)
	baseDay := time.Date(localNow.Year(), localNow.Month(), localNow.Day(), 0, 0, 0, 0, location)
	if explicitDate {
		baseDay = baseDay.AddDate(0, 0, dateOffset)
	}
	hour, minute := 0, 0
	due := false
	for _, match := range dates {
		due = due || match.due
	}
	if len(times) == 1 {
		hour, minute = times[0].hour, times[0].minute
		due = due || times[0].due
	}
	moment := time.Date(baseDay.Year(), baseDay.Month(), baseDay.Day(), hour, minute, 0, 0, location)
	if !explicitDate && len(times) == 1 {
		currentMinute := time.Date(localNow.Year(), localNow.Month(), localNow.Day(), localNow.Hour(), localNow.Minute(), 0, 0, location)
		if moment.Before(currentMinute) {
			moment = moment.AddDate(0, 0, 1)
		}
	}
	if explicitDate && dateOffset == 0 && len(times) == 1 && moment.Before(localNow) {
		draft.PastExplicit = true
	}
	draft.Status = "planned"
	if due {
		draft.Due = &moment
	} else {
		draft.Scheduled = &moment
	}
	return draft, nil
}

func tokenize(input string) []token {
	tokens := make([]token, 0, len(input)/3)
	for offset := 0; offset < len(input); {
		r, size := utf8.DecodeRuneInString(input[offset:])
		if unicode.IsSpace(r) {
			offset += size
			continue
		}
		start := offset
		kind := punctuationToken
		switch {
		case unicode.IsLetter(r):
			kind = wordToken
			for offset < len(input) {
				next, nextSize := utf8.DecodeRuneInString(input[offset:])
				if !unicode.IsLetter(next) {
					break
				}
				offset += nextSize
			}
		case r >= '0' && r <= '9':
			kind = numberToken
			for offset < len(input) {
				next, nextSize := utf8.DecodeRuneInString(input[offset:])
				if next < '0' || next > '9' {
					break
				}
				offset += nextSize
			}
		default:
			offset += size
		}
		if offset == start {
			offset += size
		}
		raw := input[start:offset]
		tokens = append(tokens, token{
			raw:        raw,
			normalized: normalizeWord(raw),
			start:      start,
			end:        offset,
			kind:       kind,
		})
	}
	return tokens
}

func normalizeWord(value string) string {
	return strings.ReplaceAll(strings.ToLower(value), "ё", "е")
}

func commandPrefix(tokens []token) (span, bool) {
	patterns := [][]string{
		{"создай", "мне", "задачу"},
		{"поставь", "мне", "задачу"},
		{"добавь", "мне", "задачу"},
		{"добавь", "мне"},
		{"запиши", "мне"},
		{"напомни", "мне"},
		{"мне", "нужно"},
		{"создай", "задачу"},
		{"поставь", "задачу"},
		{"добавь", "задачу"},
		{"напомни"},
		{"запиши"},
		{"добавь"},
		{"надо"},
	}
	words := make([]token, 0, len(tokens))
	for _, candidate := range tokens {
		if candidate.kind == punctuationToken && len(words) == 0 {
			continue
		}
		if candidate.kind != wordToken {
			break
		}
		words = append(words, candidate)
	}
	for _, pattern := range patterns {
		if len(words) < len(pattern) {
			continue
		}
		matched := true
		for index, expected := range pattern {
			if words[index].normalized != expected {
				matched = false
				break
			}
		}
		if matched {
			return span{start: words[0].start, end: words[len(pattern)-1].end}, true
		}
	}
	return span{}, false
}

func findDates(tokens []token) []dateMatch {
	offsets := map[string]int{"сегодня": 0, "завтра": 1, "послезавтра": 2}
	matches := make([]dateMatch, 0, 2)
	for index, candidate := range tokens {
		offset, ok := offsets[candidate.normalized]
		if !ok || candidate.kind != wordToken {
			continue
		}
		matchedSpan := span{start: candidate.start, end: candidate.end}
		due := false
		if index > 0 && isImmediate(tokens[index-1], candidate) {
			switch tokens[index-1].normalized {
			case "до", "к":
				due = true
				matchedSpan.start = tokens[index-1].start
			case "в", "на":
				matchedSpan.start = tokens[index-1].start
			}
		}
		matches = append(matches, dateMatch{offset: offset, span: matchedSpan, due: due})
	}
	return matches
}

func findTimes(tokens []token, explicitDate bool) ([]timeMatch, bool) {
	matches := make([]timeMatch, 0, 2)
	invalid := false
	for index := 0; index < len(tokens); {
		candidate, consumed, candidateInvalid, ok := numericSeparatedTime(tokens, index, explicitDate)
		if ok || candidateInvalid {
			invalid = invalid || candidateInvalid
			if ok {
				matches = append(matches, candidate)
			}
			index += max(1, consumed)
			continue
		}
		candidate, consumed, candidateInvalid, ok = prepositionalTime(tokens, index)
		if ok || candidateInvalid {
			invalid = invalid || candidateInvalid
			if ok {
				matches = append(matches, candidate)
			}
			index += max(1, consumed)
			continue
		}
		index++
	}
	return matches, invalid
}

func numericSeparatedTime(tokens []token, index int, explicitDate bool) (timeMatch, int, bool, bool) {
	if index+2 >= len(tokens) || tokens[index].kind != numberToken || tokens[index+2].kind != numberToken {
		return timeMatch{}, 0, false, false
	}
	separator := tokens[index+1].raw
	if separator != ":" && separator != "." {
		return timeMatch{}, 0, false, false
	}
	startIndex := index
	hasPreposition := false
	if index > 0 && isTimePreposition(tokens[index-1].normalized) && isImmediate(tokens[index-1], tokens[index]) {
		startIndex = index - 1
		hasPreposition = true
	}
	if separator == "." && !explicitDate && !hasPreposition {
		return timeMatch{}, 0, false, false
	}
	hour, hourError := strconv.Atoi(tokens[index].raw)
	minute, minuteError := strconv.Atoi(tokens[index+2].raw)
	invalid := hourError != nil || minuteError != nil || hour > 23 || minute > 59
	matched := timeMatch{
		hour: hour, minute: minute,
		span: span{start: tokens[startIndex].start, end: tokens[index+2].end},
		due:  startIndex != index && isDuePreposition(tokens[startIndex].normalized),
	}
	return matched, 3, invalid, !invalid
}

func prepositionalTime(tokens []token, index int) (timeMatch, int, bool, bool) {
	if index >= len(tokens) || !isTimePreposition(tokens[index].normalized) || index+1 >= len(tokens) {
		return timeMatch{}, 0, false, false
	}
	if !isImmediate(tokens[index], tokens[index+1]) {
		return timeMatch{}, 0, false, false
	}
	if index+3 < len(tokens) && tokens[index+1].kind == numberToken &&
		(tokens[index+2].raw == ":" || tokens[index+2].raw == ".") && tokens[index+3].kind == numberToken {
		matched, _, invalid, ok := numericSeparatedTime(tokens, index+1, true)
		return matched, 4, invalid, ok
	}
	valueIndex := index + 1
	hour, hourCount, ok := parseNumber(tokens, valueIndex, 999)
	if !ok {
		return timeMatch{}, 0, false, false
	}
	endIndex := valueIndex + hourCount - 1
	minute := 0
	nextIndex := endIndex + 1
	if nextIndex < len(tokens) && isImmediate(tokens[endIndex], tokens[nextIndex]) {
		if tokens[nextIndex].normalized == "час" || tokens[nextIndex].normalized == "часа" || tokens[nextIndex].normalized == "часов" {
			endIndex = nextIndex
			nextIndex++
		} else if parsedMinute, minuteCount, minuteOK := parseMinute(tokens, nextIndex); minuteOK {
			minute = parsedMinute
			endIndex = nextIndex + minuteCount - 1
			nextIndex = endIndex + 1
		}
	}
	if nextIndex < len(tokens) && isImmediate(tokens[endIndex], tokens[nextIndex]) {
		adjustedHour, partOK := applyDayPart(hour, tokens[nextIndex].normalized)
		if partOK {
			hour = adjustedHour
			endIndex = nextIndex
		}
	}
	invalid := hour > 23 || minute > 59
	return timeMatch{
		hour: hour, minute: minute,
		span: span{start: tokens[index].start, end: tokens[endIndex].end},
		due:  isDuePreposition(tokens[index].normalized),
	}, endIndex - index + 1, invalid, !invalid
}

func parseMinute(tokens []token, index int) (int, int, bool) {
	if index >= len(tokens) {
		return 0, 0, false
	}
	if index+1 < len(tokens) && isImmediate(tokens[index], tokens[index+1]) {
		if tokens[index].normalized == "ноль" && tokens[index+1].normalized == "ноль" {
			return 0, 2, true
		}
	}
	return parseNumber(tokens, index, 999)
}

func parseNumber(tokens []token, index int, maximum int) (int, int, bool) {
	if index >= len(tokens) {
		return 0, 0, false
	}
	if tokens[index].kind == numberToken {
		value, err := strconv.Atoi(tokens[index].raw)
		if err != nil {
			return 0, 0, false
		}
		return value, 1, value <= maximum
	}
	if tokens[index].kind != wordToken {
		return 0, 0, false
	}
	singles := map[string]int{
		"ноль": 0, "один": 1, "одна": 1, "два": 2, "две": 2, "три": 3, "четыре": 4,
		"пять": 5, "шесть": 6, "семь": 7, "восемь": 8, "девять": 9,
		"десять": 10, "одиннадцать": 11, "двенадцать": 12, "тринадцать": 13,
		"четырнадцать": 14, "пятнадцать": 15, "шестнадцать": 16, "семнадцать": 17,
		"восемнадцать": 18, "девятнадцать": 19,
	}
	if value, ok := singles[tokens[index].normalized]; ok {
		return value, 1, value <= maximum
	}
	tens := map[string]int{"двадцать": 20, "тридцать": 30, "сорок": 40, "пятьдесят": 50}
	base, ok := tens[tokens[index].normalized]
	if !ok {
		return 0, 0, false
	}
	count := 1
	value := base
	if index+1 < len(tokens) && isImmediate(tokens[index], tokens[index+1]) {
		if unit, unitOK := singles[tokens[index+1].normalized]; unitOK && unit > 0 && unit < 10 {
			value += unit
			count = 2
		}
	}
	return value, count, value <= maximum
}

func applyDayPart(hour int, part string) (int, bool) {
	switch part {
	case "утра":
		if hour == 12 {
			return 0, true
		}
		return hour, hour <= 11
	case "дня", "вечера":
		if hour >= 1 && hour <= 11 {
			return hour + 12, true
		}
		return hour, hour == 12
	case "ночи":
		if hour == 12 {
			return 0, true
		}
		return hour, hour <= 5
	default:
		return hour, false
	}
}

func isTimePreposition(value string) bool {
	return value == "в" || value == "до" || value == "к"
}

func isDuePreposition(value string) bool { return value == "до" || value == "к" }

func isImmediate(left token, right token) bool {
	return left.end <= right.start
}

func hasUnsupportedDateTime(input string, _ []token, removals []span) bool {
	leftover := strings.ToLower(titleWithoutSpansRaw(input, removals))
	leftover = strings.ReplaceAll(leftover, "ё", "е")
	if calendarDatePattern.MatchString(leftover) {
		return true
	}
	unsupportedWords := map[string]bool{
		"понедельник": true, "понедельника": true, "понедельнику": true,
		"вторник": true, "вторника": true, "вторнику": true,
		"среда": true, "среду": true, "среды": true,
		"четверг": true, "четверга": true, "четвергу": true,
		"пятница": true, "пятницу": true, "пятницы": true,
		"суббота": true, "субботу": true, "субботы": true,
		"воскресенье": true, "воскресенья": true,
		"января": true, "февраля": true, "марта": true, "апреля": true, "мая": true, "июня": true,
		"июля": true, "августа": true, "сентября": true, "октября": true, "ноября": true, "декабря": true,
		"утром": true, "вечером": true, "ночью": true, "полседьмого": true,
	}
	leftoverTokens := tokenize(leftover)
	for index, candidate := range leftoverTokens {
		if unsupportedWords[candidate.normalized] {
			return true
		}
		if candidate.normalized == "через" && index+1 < len(leftoverTokens) {
			_, count, numberOK := parseNumber(leftoverTokens, index+1, 999)
			unitIndex := index + 1 + count
			if numberOK && unitIndex < len(leftoverTokens) && isTimeUnit(leftoverTokens[unitIndex].normalized) {
				return true
			}
		}
		if candidate.normalized == "без" && index+1 < len(leftoverTokens) {
			if _, _, ok := parseNumber(leftoverTokens, index+1, 59); ok || leftoverTokens[index+1].normalized == "десяти" {
				return true
			}
		}
		if candidate.normalized == "после" && index+1 < len(leftoverTokens) && leftoverTokens[index+1].normalized == "обеда" {
			return true
		}
	}
	return false
}

func isTimeUnit(value string) bool {
	switch value {
	case "минута", "минуты", "минут", "час", "часа", "часов", "день", "дня", "дней", "неделя", "недели", "недель":
		return true
	default:
		return false
	}
}

func titleWithoutSpans(input string, removals []span) string {
	raw := titleWithoutSpansRaw(input, removals)
	cleaned := strings.Join(strings.Fields(raw), " ")
	cleaned = strings.Trim(cleaned, " \t\n\r,.;:!?—–-")
	if cleaned == "" {
		return ""
	}
	runes := []rune(cleaned)
	for index, value := range runes {
		if unicode.IsLetter(value) {
			runes[index] = unicode.ToUpper(value)
			break
		}
	}
	return string(runes)
}

func titleWithoutSpansRaw(input string, removals []span) string {
	if len(removals) == 0 {
		return input
	}
	sort.Slice(removals, func(left, right int) bool { return removals[left].start < removals[right].start })
	merged := make([]span, 0, len(removals))
	for _, candidate := range removals {
		if candidate.start < 0 || candidate.end > len(input) || candidate.start >= candidate.end {
			continue
		}
		if len(merged) == 0 || candidate.start > merged[len(merged)-1].end {
			merged = append(merged, candidate)
			continue
		}
		if candidate.end > merged[len(merged)-1].end {
			merged[len(merged)-1].end = candidate.end
		}
	}
	var builder strings.Builder
	cursor := 0
	for _, removal := range merged {
		builder.WriteString(input[cursor:removal.start])
		builder.WriteByte(' ')
		cursor = removal.end
	}
	builder.WriteString(input[cursor:])
	return builder.String()
}

func max(left, right int) int {
	if left > right {
		return left
	}
	return right
}
