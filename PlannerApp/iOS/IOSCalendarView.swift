import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
private enum IOSCalendarMode: String, CaseIterable, Identifiable {
    case week, day
    var id: String { rawValue }
    var title: String { self == .week ? "Неделя" : "День" }
}

struct IOSCalendarView: View {
    let week: CalendarWeek
    let placements: [CalendarTaskPlacement]
    let eventOccurrences: [CalendarEventOccurrence]
    @Binding var searchText: String
    let isCurrentWeek: Bool
    let goToPreviousWeek: () -> Void
    let goToNextWeek: () -> Void
    let goToCurrentWeek: () -> Void
    let movePlacement: (CalendarTaskPlacement, Date) -> Void
    let resizePlacement: (CalendarTaskPlacement, Date) -> Void
    let openTask: (PlannerTask) -> Void
    let completeTask: (PlannerTask) -> Void
    let openEvent: (CalendarEventOccurrence) -> Void
    let moveEvent: (CalendarEventOccurrence, Date) -> Void
    let resizeEvent: (CalendarEventOccurrence, Date) -> Void
    let createEvent: (Date) -> Void

    @AppStorage("ios.calendar.mode") private var modeRawValue = IOSCalendarMode.week.rawValue
    @State private var selectedDayIndex = 0

    private var mode: Binding<IOSCalendarMode> {
        Binding(
            get: { IOSCalendarMode(rawValue: modeRawValue) ?? .week },
            set: { modeRawValue = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Режим", selection: mode) {
                ForEach(IOSCalendarMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])

            if mode.wrappedValue == .week {
                weekContent
            } else {
                dayContent
            }
        }
        .navigationTitle("Календарь")
        .searchable(text: $searchText, prompt: "Поиск")
        .background(PlannerTheme.windowBackground)
        .tint(PlannerTheme.accent)
        .onAppear(perform: selectTodayIfVisible)
        .onChange(of: week.startOfWeek) { _, _ in selectedDayIndex = min(6, max(0, selectedDayIndex)) }
    }

    private var weekContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                weekHeader
                ForEach(week.days) { day in
                IOSCalendarDaySection(
                        day: day,
                        placements: placementsForDay(day),
                        allPlacements: placements,
                        openTask: openTask,
                        movePlacement: movePlacement,
                        completeTask: completeTask
                        , eventOccurrences: eventOccurrencesForDay(day), openEvent: openEvent,
                        moveEvent: moveEvent, createEvent: createEvent
                    )
                }
            }
            .padding()
        }
    }

    @ViewBuilder private var dayContent: some View {
        if let day = week.days[safe: selectedDayIndex] {
            IOSCalendarDayTimeline(
                day: day,
                placements: placementsForDay(day),
                allPlacements: placements,
                previousDay: previousDay,
                nextDay: nextDay,
                goToday: { goToCurrentWeek(); selectTodayIfVisible() },
                openTask: openTask,
                movePlacement: movePlacement,
                resizePlacement: resizePlacement,
                completeTask: completeTask,
                eventOccurrences: eventOccurrencesForDay(day),
                openEvent: openEvent, moveEvent: moveEvent, resizeEvent: resizeEvent,
                createEvent: createEvent
            )
        }
    }

    private var weekHeader: some View {
        HStack(spacing: 10) {
            Button(action: goToPreviousWeek) { Image(systemName: "chevron.left") }.buttonStyle(.bordered)
            VStack(alignment: .leading, spacing: 2) {
                Text(isCurrentWeek ? "Текущая неделя" : "Выбранная неделя").font(.headline)
                Text(weekRangeText).font(.caption).foregroundStyle(PlannerTheme.secondaryText)
            }
            Spacer()
            Button("Сегодня", action: goToCurrentWeek).buttonStyle(.bordered).disabled(isCurrentWeek)
            Button(action: goToNextWeek) { Image(systemName: "chevron.right") }.buttonStyle(.bordered)
        }
        .padding(12)
        .background(PlannerTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private var weekRangeText: String {
        guard let first = week.days.first?.date, let last = week.days.last?.date else { return "" }
        return "\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))"
    }
    private func placementsForDay(_ day: CalendarDay) -> [CalendarTaskPlacement] {
        placements.filter { $0.day.id == day.id }
    }
    private func eventOccurrencesForDay(_ day: CalendarDay) -> [CalendarEventOccurrence] {
        eventOccurrences.filter { Calendar.current.isDate($0.start, inSameDayAs: day.date) }
    }
    private func selectTodayIfVisible() {
        if let index = week.days.firstIndex(where: { Calendar.current.isDateInToday($0.date) }) { selectedDayIndex = index }
    }
    private func previousDay() {
        if selectedDayIndex > 0 { selectedDayIndex -= 1 } else { selectedDayIndex = 6; goToPreviousWeek() }
    }
    private func nextDay() {
        if selectedDayIndex < 6 { selectedDayIndex += 1 } else { selectedDayIndex = 0; goToNextWeek() }
    }
}

private struct IOSCalendarDaySection: View {
    let day: CalendarDay
    let placements: [CalendarTaskPlacement]
    let allPlacements: [CalendarTaskPlacement]
    let openTask: (PlannerTask) -> Void
    let movePlacement: (CalendarTaskPlacement, Date) -> Void
    let completeTask: (PlannerTask) -> Void
    let eventOccurrences: [CalendarEventOccurrence]
    let openEvent: (CalendarEventOccurrence) -> Void
    let moveEvent: (CalendarEventOccurrence, Date) -> Void
    let createEvent: (Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    Text(day.title.capitalized).font(.headline)
                    Text(day.subtitle).font(.caption).foregroundStyle(PlannerTheme.secondaryText)
                }
                Spacer()
                Text("\(placements.count)").font(.caption).padding(6).background(PlannerTheme.elevatedBackground, in: Capsule())
            }
            if placements.isEmpty {
                Text("Нет задач").font(.caption).foregroundStyle(PlannerTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                ForEach(placements) { placement in
                    IOSCalendarPlacementRow(
                        placement: placement,
                        openTask: { openTask(placement.task) },
                        completeTask: completeTask
                    )
                }
            }
            ForEach(eventOccurrences) { occurrence in
                IOSCalendarEventRow(occurrence: occurrence, openEvent: { openEvent(occurrence) })
            }
        }
        .padding(12)
        .background(PlannerTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8))
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            CalendarDropLoader.load(providers, placements: allPlacements) { placement in
                movePlacement(placement, CalendarService.moving(placement, toDay: day))
            }
            return true
        }
        .onTapGesture(count: 2) { createEvent(day.date) }
    }
}

private struct IOSCalendarDayTimeline: View {
    let day: CalendarDay
    let placements: [CalendarTaskPlacement]
    let allPlacements: [CalendarTaskPlacement]
    let previousDay: () -> Void
    let nextDay: () -> Void
    let goToday: () -> Void
    let openTask: (PlannerTask) -> Void
    let movePlacement: (CalendarTaskPlacement, Date) -> Void
    let resizePlacement: (CalendarTaskPlacement, Date) -> Void
    let completeTask: (PlannerTask) -> Void
    let eventOccurrences: [CalendarEventOccurrence]
    let openEvent: (CalendarEventOccurrence) -> Void
    let moveEvent: (CalendarEventOccurrence, Date) -> Void
    let resizeEvent: (CalendarEventOccurrence, Date) -> Void
    let createEvent: (Date) -> Void

    private let slotHeight: CGFloat = 32
    private let axisWidth: CGFloat = 52
    private var timelineHeight: CGFloat { slotHeight * 48 }
    private var allDay: [CalendarTaskPlacement] { placements.filter(\.isAllDay) }
    private var timed: [CalendarTaskPlacement] { placements.filter { !$0.isAllDay } }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button(action: previousDay) { Image(systemName: "chevron.left") }
                VStack {
                    Text(day.title.capitalized).font(.headline)
                    Text(day.subtitle).font(.caption).foregroundStyle(PlannerTheme.secondaryText)
                }.frame(maxWidth: .infinity)
                Button("Сегодня", action: goToday).font(.caption)
                Button(action: nextDay) { Image(systemName: "chevron.right") }
            }.padding(.horizontal)

            if !allDay.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        Text("Весь день").font(.caption).foregroundStyle(PlannerTheme.secondaryText)
                        ForEach(allDay) { placement in
                            IOSCalendarPlacementRow(placement: placement, openTask: { openTask(placement.task) }, completeTask: completeTask)
                                .frame(width: 240)
                        }
                    }.padding(.horizontal)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(String(format: "%02d:00", hour)).font(.caption2)
                                    .foregroundStyle(PlannerTheme.secondaryText)
                                    .frame(width: axisWidth, height: slotHeight * 2, alignment: .topTrailing)
                                    .id(hour)
                            }
                        }
                        GeometryReader { geometry in
                            ZStack(alignment: .topLeading) {
                                IOSCalendarGrid(slotHeight: slotHeight)
                                ForEach(CalendarService.layoutOverlaps(timed)) { layout in
                                    let available = geometry.size.width - 8
                                    let laneWidth = available / CGFloat(layout.laneCount)
                                    IOSCalendarTimelineBlock(
                                        placement: layout.placement,
                                        slotHeight: slotHeight,
                                        openTask: { openTask(layout.placement.task) },
                                        completeTask: completeTask,
                                        resizePlacement: resizePlacement
                                    )
                                    .frame(width: max(54, laneWidth - 3), height: max(28, CGFloat(layout.placement.durationMinutes) / 30 * slotHeight - 2))
                                    .offset(x: 4 + CGFloat(layout.lane) * laneWidth,
                                            y: CGFloat(layout.placement.startMinute) / 30 * slotHeight)
                                }
                                ForEach(eventOccurrences) { occurrence in
                                    IOSCalendarTimelineEventBlock(
                                        occurrence: occurrence,
                                        day: day,
                                        slotHeight: slotHeight,
                                        openEvent: { openEvent(occurrence) },
                                        moveEvent: { moveEvent(occurrence, $0) },
                                        resizeEvent: { resizeEvent(occurrence, $0) }
                                    )
                                    .frame(width: max(90, geometry.size.width * 0.55),
                                           height: max(28, CGFloat(occurrence.end.timeIntervalSince(occurrence.start) / 60) / 30 * slotHeight - 2))
                                    .offset(x: geometry.size.width * 0.43,
                                            y: CGFloat(Calendar.current.component(.hour, from: occurrence.start) * 60 + Calendar.current.component(.minute, from: occurrence.start)) / 30 * slotHeight)
                                }
                            }
                            .contentShape(Rectangle())
                            .gesture(SpatialTapGesture(count: 2).onEnded { value in
                                let slot = min(47, max(0, Int(value.location.y / slotHeight)))
                                createEvent(CalendarService.date(for: day, hour: slot / 2, minute: slot.isMultiple(of: 2) ? 0 : 30))
                            })
                            .onDrop(of: [.plainText], delegate: IOSCalendarTimelineDropDelegate(
                                day: day, placements: allPlacements, slotHeight: slotHeight,
                                timelineHeight: timelineHeight, movePlacement: movePlacement))
                        }
                        .frame(height: timelineHeight)
                    }
                }
                .onAppear { proxy.scrollTo(Calendar.current.isDateInToday(day.date) ? max(0, Calendar.current.component(.hour, from: .now) - 1) : 8, anchor: .top) }
            }
        }
    }
}

private struct IOSCalendarGrid: View {
    let slotHeight: CGFloat
    var body: some View {
        Canvas { context, size in
            for index in 0...48 {
                var path = Path()
                let y = min(CGFloat(index) * slotHeight, size.height)
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(PlannerTheme.border.opacity(index.isMultiple(of: 2) ? 0.7 : 0.35)), lineWidth: 0.5)
            }
        }
        .background(PlannerTheme.rowBackground.opacity(0.35))
    }
}

private struct IOSCalendarTimelineBlock: View {
    let placement: CalendarTaskPlacement
    let slotHeight: CGFloat
    let openTask: () -> Void
    let completeTask: (PlannerTask) -> Void
    let resizePlacement: (CalendarTaskPlacement, Date) -> Void
    @State private var resizeEndMinute: Int?

    var body: some View {
        ZStack(alignment: .bottom) {
            Button(action: openTask) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(placement.task.title).font(.caption).fontWeight(.semibold).lineLimit(2)
                    Text(String(format: "%02d:%02d", placement.startMinute / 60, placement.startMinute % 60)).font(.caption2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(5)
                .background(placement.kind == .due ? PlannerTheme.danger.opacity(0.2) : PlannerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .onDrag { NSItemProvider(object: placement.id as NSString) }

            if placement.kind == .scheduled, !placement.isAllDay {
                Capsule()
                    .fill(PlannerTheme.accent.opacity(0.75))
                    .frame(width: 34, height: 4)
                    .frame(maxWidth: .infinity, minHeight: 16)
                    .contentShape(Rectangle())
                    .gesture(resizeGesture)
            }
        }
        .contextMenu { Button("Выполнить") { completeTask(placement.task) } }
        .accessibilityValue(resizeEndMinute.map { "До " + timeText($0) } ?? "")
    }

    private var baseEndMinute: Int {
        min(1_439, placement.startMinute + max(30, placement.durationMinutes))
    }
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let steps = Int((value.translation.height / slotHeight).rounded())
                resizeEndMinute = min(1_439, max(placement.startMinute + 30, baseEndMinute + steps * 30))
            }
            .onEnded { _ in
                defer { resizeEndMinute = nil }
                guard let end = resizeEndMinute, end != baseEndMinute else { return }
                let due = CalendarService.date(for: placement.day, hour: end / 60, minute: end % 60)
                resizePlacement(placement, due)
            }
    }
    private func timeText(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

private struct IOSCalendarPlacementRow: View {
    let placement: CalendarTaskPlacement
    let openTask: () -> Void
    let completeTask: (PlannerTask) -> Void
    var body: some View {
        HStack(spacing: 10) {
            Button { completeTask(placement.task) } label: {
                Image(systemName: placement.task.status == .done ? "checkmark.circle.fill" : "circle")
            }.buttonStyle(.plain).disabled(placement.task.status == .done)
            Button(action: openTask) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(placement.task.title).fontWeight(.medium).foregroundStyle(.primary)
                    Text(timeText + " · " + placement.kind.title).font(.caption)
                        .foregroundStyle(placement.kind == .due ? PlannerTheme.danger : PlannerTheme.secondaryText)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
        }
        .padding(10)
        .background(PlannerTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 8))
        .onDrag { NSItemProvider(object: placement.id as NSString) }
    }
    private var timeText: String {
        placement.isAllDay ? "Весь день" : String(format: "%02d:%02d", placement.startMinute / 60, placement.startMinute % 60)
    }
}

private struct IOSCalendarEventRow: View {
    let occurrence: CalendarEventOccurrence
    let openEvent: () -> Void

    var body: some View {
        Button(action: openEvent) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock")
                    .foregroundStyle(PlannerTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(occurrence.title).fontWeight(.medium).foregroundStyle(.primary)
                    Text("\(timeText(occurrence.start))–\(timeText(occurrence.end)) · расписание")
                        .font(.caption).foregroundStyle(PlannerTheme.secondaryText)
                }
                Spacer()
                if occurrence.project != nil { Image(systemName: "folder.fill").font(.caption) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PlannerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func timeText(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}

private struct IOSCalendarTimelineEventBlock: View {
    let occurrence: CalendarEventOccurrence
    let day: CalendarDay
    let slotHeight: CGFloat
    let openEvent: () -> Void
    let moveEvent: (Date) -> Void
    let resizeEvent: (Date) -> Void

    var body: some View {
        Button(action: openEvent) {
            VStack(alignment: .leading, spacing: 2) {
                Text(occurrence.title).font(.caption).fontWeight(.semibold).lineLimit(1)
                Text("\(occurrence.start.formatted(date: .omitted, time: .shortened))–\(occurrence.end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).lineLimit(1)
            }
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(eventColor.opacity(0.24), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(eventColor.opacity(0.8), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 10).onEnded { value in
            let slots = Int((value.translation.height / slotHeight).rounded())
            guard slots != 0 else { return }
            moveEvent(occurrence.start.addingTimeInterval(Double(slots * 30 * 60)))
        })
        .overlay(alignment: .bottom) {
            Capsule().fill(eventColor).frame(width: 36, height: 5).padding(.bottom, 3)
                .gesture(DragGesture(minimumDistance: 5).onEnded { value in
                    let slots = Int((value.translation.height / slotHeight).rounded())
                    guard slots != 0 else { return }
                    let proposed = occurrence.end.addingTimeInterval(Double(slots * 30 * 60))
                    if proposed > occurrence.start { resizeEvent(proposed) }
                })
        }
    }

    private var eventColor: Color {
        guard let preset = occurrence.project?.colorPreset else { return PlannerTheme.accent }
        return PlannerTheme.projectAccent(preset)
    }
}

private struct IOSCalendarTimelineDropDelegate: DropDelegate {
    let day: CalendarDay
    let placements: [CalendarTaskPlacement]
    let slotHeight: CGFloat
    let timelineHeight: CGFloat
    let movePlacement: (CalendarTaskPlacement, Date) -> Void
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        let y = min(max(0, info.location.y), timelineHeight - 1)
        let minute = min(1_410, max(0, Int(y / slotHeight) * 30))
        CalendarDropLoader.load(info.itemProviders(for: [.plainText]), placements: placements) { placement in
            movePlacement(placement, CalendarService.moving(placement, toDay: day, minuteOfDay: minute))
        }
        return true
    }
}

private enum CalendarDropLoader {
    static func load(_ providers: [NSItemProvider], placements: [CalendarTaskPlacement], completion: @escaping (CalendarTaskPlacement) -> Void) {
        providers.first?.loadObject(ofClass: NSString.self) { object, _ in
            guard let raw = object as? String else { return }
            DispatchQueue.main.async {
                let placement = placements.first { $0.id == raw }
                    ?? UUID(uuidString: raw).flatMap { id in placements.first { $0.task.id == id } }
                if let placement { completion(placement) }
            }
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
