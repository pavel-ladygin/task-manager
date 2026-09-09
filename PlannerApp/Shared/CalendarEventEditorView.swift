import SwiftData
import SwiftUI

/// Editor shared by both platform calendar screens. The parent owns persistence so
/// the same form can be used for a new event, a series, or an occurrence override.
struct CalendarEventEditorView: View {
    let event: CalendarEvent?
    let occurrence: CalendarEventOccurrence?
    let projects: [Project]
    let defaultStart: Date
    let defaultReminder: CalendarEventReminder
    let onSave: (_ values: CalendarEventEditorValues) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @State private var title: String
    @State private var notes: String
    @State private var start: Date
    @State private var end: Date
    @State private var recurrence: CalendarEventRecurrence
    @State private var recurrenceEndDate: Date?
    @State private var reminder: CalendarEventReminder
    @State private var projectID: UUID?
    @State private var hasRecurrenceEnd: Bool

    init(event: CalendarEvent? = nil, occurrence: CalendarEventOccurrence? = nil,
         projects: [Project], defaultStart: Date = .now,
         defaultReminder: CalendarEventReminder = .fifteenMinutes,
         onSave: @escaping (_ values: CalendarEventEditorValues) -> Void,
         onDelete: (() -> Void)? = nil,
         onCancel: @escaping () -> Void) {
        self.event = event
        self.occurrence = occurrence
        self.projects = projects
        self.defaultStart = defaultStart
        self.defaultReminder = defaultReminder
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        let sourceStart = occurrence?.start ?? event?.start ?? defaultStart
        let sourceEnd = occurrence?.end ?? event?.end ?? defaultStart.addingTimeInterval(1800)
        _title = State(initialValue: occurrence?.title ?? event?.title ?? "")
        _notes = State(initialValue: occurrence?.notes ?? event?.notes ?? "")
        _start = State(initialValue: sourceStart)
        _end = State(initialValue: sourceEnd)
        _recurrence = State(initialValue: event?.recurrence ?? .none)
        _recurrenceEndDate = State(initialValue: event?.recurrenceEndDate)
        _reminder = State(initialValue: event?.reminder ?? defaultReminder)
        _projectID = State(initialValue: occurrence?.project?.id ?? event?.project?.id)
        _hasRecurrenceEnd = State(initialValue: event?.recurrenceEndDate != nil)
    }

    var body: some View {
        Form {
            Section("Событие") {
                TextField("Название", text: $title)
                DatePicker("Начало", selection: $start)
                DatePicker("Окончание", selection: $end, in: start...)
                Picker("Проект", selection: $projectID) {
                    Text("Без проекта").tag(nil as UUID?)
                    ForEach(projects) { project in
                        Text(project.title).tag(project.id as UUID?)
                    }
                }
                Picker("Повтор", selection: $recurrence) {
                    ForEach(CalendarEventRecurrence.allCases) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                if recurrence != .none {
                    Toggle("Дата окончания повтора", isOn: $hasRecurrenceEnd)
                    if hasRecurrenceEnd {
                        DatePicker("Повторять до", selection: recurrenceEndBinding, in: start..., displayedComponents: .date)
                    }
                }
                Picker("Напоминание", selection: $reminder) {
                    ForEach(CalendarEventReminder.allCases) { value in
                        Text(value.displayName).tag(value)
                    }
                }
            }
            Section("Заметка") {
                TextEditor(text: $notes).frame(minHeight: 80)
            }
            if occurrence != nil, event?.recurrence != CalendarEventRecurrence.none {
                Text("Изменения применятся к выбранному вхождению серии.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            if let onDelete {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Удалить", role: .destructive, action: onDelete)
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Отмена", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить") {
                    onSave(CalendarEventEditorValues(
                        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        notes: notes,
                        start: start,
                        end: end,
                        recurrence: recurrence,
                        recurrenceEndDate: hasRecurrenceEnd && recurrence != .none ? recurrenceEndDate : nil,
                        reminder: reminder,
                        projectID: projectID
                    ))
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || end <= start)
            }
        }
        .navigationTitle(event == nil ? "Новое событие" : "Событие")
    }

    private var recurrenceEndBinding: Binding<Date> {
        Binding(
            get: { recurrenceEndDate ?? start },
            set: { recurrenceEndDate = $0 }
        )
    }
}

struct CalendarEventEditorValues {
    let title: String
    let notes: String
    let start: Date
    let end: Date
    let recurrence: CalendarEventRecurrence
    let recurrenceEndDate: Date?
    let reminder: CalendarEventReminder
    let projectID: UUID?
}
