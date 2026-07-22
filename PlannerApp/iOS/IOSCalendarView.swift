import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
struct IOSCalendarView: View {
    let week: CalendarWeek
    let placements: [CalendarTaskPlacement]
    let projects: [Project]
    @Binding var searchText: String
    let isCurrentWeek: Bool
    let goToPreviousWeek: () -> Void
    let goToNextWeek: () -> Void
    let goToCurrentWeek: () -> Void
    let rescheduleTask: (PlannerTask, Date) -> Void
    let completeTask: (PlannerTask) -> Void

    @State private var selectedTask: PlannerTask?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                weekHeader

                ForEach(week.days) { day in
                    IOSCalendarDaySection(
                        day: day,
                        placements: placements(for: day),
                        allPlacements: placements,
                        openTask: { selectedTask = $0 },
                        rescheduleTask: rescheduleTask,
                        completeTask: completeTask
                    )
                }
            }
            .padding()
        }
        .navigationTitle("Календарь")
        .searchable(text: $searchText, prompt: "Поиск")
        .scrollContentBackground(.hidden)
        .background(PlannerTheme.windowBackground)
        .tint(PlannerTheme.accent)
        .sheet(item: $selectedTask) { task in
            NavigationStack {
                IOSTaskDetailView(task: task, projects: projects)
            }
        }
    }

    private var weekHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(action: goToPreviousWeek) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isCurrentWeek ? "Текущая неделя" : "Выбранная неделя")
                        .font(.headline)

                    Text(weekRangeText)
                        .font(.caption)
                        .foregroundStyle(PlannerTheme.secondaryText)
                }

                Spacer()

                Button("Сегодня", action: goToCurrentWeek)
                    .buttonStyle(.bordered)
                    .disabled(isCurrentWeek)

                Button(action: goToNextWeek) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
            }

            Text("Листайте недели кнопками или перетащите задачу на нужный день.")
                .font(.caption)
                .foregroundStyle(PlannerTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(PlannerTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(PlannerTheme.subtleBorder, lineWidth: 0.5)
        )
    }

    private var weekRangeText: String {
        guard let first = week.days.first?.date, let last = week.days.last?.date else {
            return ""
        }

        return "\(first.formatted(date: .abbreviated, time: .omitted)) - \(last.formatted(date: .abbreviated, time: .omitted))"
    }

    private func placements(for day: CalendarDay) -> [CalendarTaskPlacement] {
        placements.filter { $0.day.id == day.id }
    }
}

private struct IOSCalendarDaySection: View {
    let day: CalendarDay
    let placements: [CalendarTaskPlacement]
    let allPlacements: [CalendarTaskPlacement]
    let openTask: (PlannerTask) -> Void
    let rescheduleTask: (PlannerTask, Date) -> Void
    let completeTask: (PlannerTask) -> Void

    private var allDayPlacements: [CalendarTaskPlacement] {
        placements.filter(\.isAllDay)
    }

    private var timedPlacements: [CalendarTaskPlacement] {
        placements.filter { !$0.isAllDay }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(day.title.capitalized)
                        .font(.headline)

                    Text(day.subtitle)
                        .font(.caption)
                        .foregroundStyle(PlannerTheme.secondaryText)
                }

                Spacer()

                Text("\(placements.count)")
                    .font(.caption)
                    .foregroundStyle(PlannerTheme.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(PlannerTheme.elevatedBackground, in: Capsule())
            }

            if placements.isEmpty {
                Text("Нет задач")
                    .font(.caption)
                    .foregroundStyle(PlannerTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(PlannerTheme.rowBackground, in: RoundedRectangle(cornerRadius: 8))
            } else {
                if !allDayPlacements.isEmpty {
                    Text("Весь день")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(PlannerTheme.secondaryText)

                    ForEach(allDayPlacements) { placement in
                        IOSCalendarPlacementRow(
                            placement: placement,
                            openTask: { openTask(placement.task) },
                            completeTask: completeTask
                        )
                    }
                }

                if !timedPlacements.isEmpty {
                    Text("По времени")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(PlannerTheme.secondaryText)

                    ForEach(timedPlacements) { placement in
                        IOSCalendarPlacementRow(
                            placement: placement,
                            openTask: { openTask(placement.task) },
                            completeTask: completeTask
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(PlannerTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(PlannerTheme.subtleBorder, lineWidth: 0.5)
        )
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            loadTask(from: providers) { task in
                rescheduleTask(task, CalendarService.date(for: day, hour: 9, minute: 0))
            }

            return true
        }
    }

    private func loadTask(
        from providers: [NSItemProvider],
        completion: @escaping (PlannerTask) -> Void
    ) {
        guard let provider = providers.first else {
            return
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard
                let rawID = object as? String,
                let taskID = UUID(uuidString: rawID)
            else {
                return
            }

            DispatchQueue.main.async {
                guard let task = allPlacements.first(where: { $0.task.id == taskID })?.task else {
                    return
                }

                completion(task)
            }
        }
    }
}

private struct IOSCalendarPlacementRow: View {
    let placement: CalendarTaskPlacement
    let openTask: () -> Void
    let completeTask: (PlannerTask) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                completeTask(placement.task)
            } label: {
                Image(systemName: placement.task.status == .done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(placement.task.status == .done ? PlannerTheme.success : PlannerTheme.secondaryText)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(placement.task.status == .done)

            Button(action: openTask) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Image(systemName: placement.kind == .due ? "flag.fill" : "calendar")
                            .foregroundStyle(placement.kind == .due ? PlannerTheme.danger : PlannerTheme.accent)

                        Text(timeText)
                            .font(.caption)
                            .foregroundStyle(PlannerTheme.secondaryText)

                        Spacer()
                    }

                    Text(placement.task.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        Text(placement.kind.title)
                            .foregroundStyle(placement.kind == .due ? PlannerTheme.danger : PlannerTheme.accent)

                        Text(placement.task.priority.displayName)

                        if let projectTitle = placement.task.project?.title {
                            Text(projectTitle)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(PlannerTheme.secondaryText)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(PlannerTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(placement.kind == .due ? PlannerTheme.danger.opacity(0.35) : PlannerTheme.accent.opacity(0.35), lineWidth: 0.5)
        )
        .onDrag {
            NSItemProvider(object: placement.task.id.uuidString as NSString)
        }
    }

    private var timeText: String {
        if placement.isAllDay {
            return "Весь день"
        }

        let start = String(format: "%02d:%02d", placement.startMinute / 60, placement.startMinute % 60)
        let endMinute = min(1_439, placement.startMinute + placement.durationMinutes)
        let end = String(format: "%02d:%02d", endMinute / 60, endMinute % 60)

        return "\(start) - \(end)"
    }
}
#endif
