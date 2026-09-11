import Foundation
import SwiftData
import XCTest
@testable import PlannerApp_macOS

final class PlannerCoreTests: XCTestCase {
    func testTelegramTaskPayloadDecodesAsSyncTask() throws {
        let json = """
        {
          "id": "00000000-0000-4000-8000-000000000007",
          "title": "Позвонить врачу",
          "notes": "",
          "status": "planned",
          "priority": "none",
          "recurrence": "none",
          "recurrenceSeriesID": null,
          "recurrenceAnchorDate": null,
          "recurrenceSequence": 0,
          "showInKanban": true,
          "scheduled": "2026-09-08T15:00:00+03:00",
          "due": null,
          "createdAt": "2026-09-07T18:00:00+03:00",
          "updatedAt": "2026-09-07T18:00:00+03:00",
          "completedAt": null,
          "projectID": null,
          "tagIDs": [],
          "checklistItems": [],
          "manualOrder": 0
        }
        """
        let task = try SyncClient.decoder.decode(TaskBackupDTO.self, from: Data(json.utf8))

        XCTAssertEqual(task.id.uuidString.lowercased(), "00000000-0000-4000-8000-000000000007")
        XCTAssertEqual(task.title, "Позвонить врачу")
        XCTAssertEqual(task.status, "planned")
        XCTAssertNotNil(task.scheduled)
        XCTAssertNil(task.due)
    }

    @MainActor
    func testSyncPullDoesNotOverwriteEntityWithPendingLocalMutation() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let settings = AppSettings()
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let task = PlannerTask(id: id, title: "Выполнено локально", status: .done, completedAt: now)
        context.insert(settings)
        context.insert(task)
        context.insert(SyncEntityState(entityType: .task, entityID: id.uuidString, serverRevision: 12, payloadHash: "local-hash"))
        context.insert(SyncOutboxItem(
            entityType: .task, entityID: id.uuidString, operation: .upsert,
            payloadJSON: "{\"status\":\"done\"}", baseRevision: 12
        ))
        try context.save()

        let serverDTO = TaskBackupDTO(
            id: id, title: "Старое серверное состояние", notes: "", status: TaskStatus.planned.rawValue,
            priority: Priority.none.rawValue, recurrence: TaskRecurrence.none.rawValue,
            recurrenceSeriesID: nil, recurrenceAnchorDate: nil, recurrenceSequence: 0,
            showInKanban: true, scheduled: now, due: nil, createdAt: now, updatedAt: now,
            completedAt: nil, projectID: nil, tagIDs: [], checklistItems: [], manualOrder: 0
        )
        let payload = try JSONDecoder().decode(JSONValue.self, from: SyncClient.encoder.encode(serverDTO))
        let change = SyncServerChangeDTO(
            revision: 13, entityType: SyncEntityType.task.rawValue, entityID: id.uuidString,
            operation: SyncMutationOperation.upsert.rawValue, payload: payload,
            sourceDeviceID: "other-device", serverUpdatedAt: now
        )

        try SyncService.apply(changes: [change], context: context, settings: settings)

        XCTAssertEqual(task.status, .done)
        XCTAssertEqual(task.title, "Выполнено локально")
        let state = try XCTUnwrap(context.fetch(FetchDescriptor<SyncEntityState>()).first)
        XCTAssertEqual(state.serverRevision, 12)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SyncOutboxItem>()).first?.baseRevision, 12)
    }

    @MainActor
    func testSyncPullDoesNotDeleteEntityWithPendingLocalDeletion() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let settings = AppSettings()
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let task = PlannerTask(id: id, title: "Удаляется локально")
        context.insert(settings)
        context.insert(task)
        context.insert(SyncEntityState(entityType: .task, entityID: id.uuidString, serverRevision: 20, payloadHash: "hash"))
        context.insert(SyncOutboxItem(
            entityType: .task, entityID: id.uuidString, operation: .delete,
            payloadJSON: nil, baseRevision: 20
        ))
        try context.save()

        let change = SyncServerChangeDTO(
            revision: 21, entityType: SyncEntityType.task.rawValue, entityID: id.uuidString,
            operation: SyncMutationOperation.delete.rawValue, payload: nil,
            sourceDeviceID: "other-device", serverUpdatedAt: now
        )
        try SyncService.apply(changes: [change], context: context, settings: settings)

        XCTAssertNotNil(try context.fetch(FetchDescriptor<PlannerTask>()).first { $0.id == id })
        XCTAssertEqual(try context.fetch(FetchDescriptor<SyncEntityState>()).first?.serverRevision, 20)
    }

    func testWeekdaysSkipsWeekend() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let friday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 24, hour: 9)))
        let monday = try XCTUnwrap(RecurrenceService.occurrenceDate(recurrence: .weekdays, anchor: friday, sequence: 1, calendar: calendar))
        XCTAssertEqual(calendar.component(.weekday, from: monday), 2)
        XCTAssertEqual(calendar.component(.day, from: monday), 27)
    }

    func testMonthlyAndYearlyClampButKeepAnchor() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let january31 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 10)))
        let february = try XCTUnwrap(RecurrenceService.occurrenceDate(recurrence: .monthly, anchor: january31, sequence: 1, calendar: calendar))
        let march = try XCTUnwrap(RecurrenceService.occurrenceDate(recurrence: .monthly, anchor: january31, sequence: 2, calendar: calendar))
        XCTAssertEqual(calendar.component(.day, from: february), 28)
        XCTAssertEqual(calendar.component(.day, from: march), 31)

        let leapDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 2, day: 29, hour: 8)))
        let nextYear = try XCTUnwrap(RecurrenceService.occurrenceDate(recurrence: .yearly, anchor: leapDay, sequence: 1, calendar: calendar))
        XCTAssertEqual(calendar.component(.day, from: nextYear), 28)
    }

    func testDailyRecurrenceKeepsLocalTimeAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let beforeDST = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 9)))
        let afterDST = try XCTUnwrap(RecurrenceService.occurrenceDate(recurrence: .daily, anchor: beforeDST, sequence: 1, calendar: calendar))
        XCTAssertEqual(calendar.component(.hour, from: afterDST), 9)
        XCTAssertEqual(afterDST.timeIntervalSince(beforeDST), 23 * 60 * 60)
    }

    func testWidgetChangesDayAcrossDSTAndKeepsOverdueTasks() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        let overdue = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 18)))
        let todayLate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 23, minute: 30)))
        let tomorrow = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, minute: 1)))

        let tasks = [
            widgetTask(title: "Tomorrow", priority: "urgent", due: tomorrow),
            widgetTask(title: "Today", priority: "medium", due: todayLate),
            widgetTask(title: "Overdue", priority: "high", due: overdue)
        ]

        let todayTasks = PlannerWidgetTaskList.tasks(for: today, from: tasks, calendar: calendar)
        XCTAssertEqual(todayTasks.map(\.title), ["Overdue", "Today"])

        let tomorrowTasks = PlannerWidgetTaskList.tasks(for: tomorrow, from: tasks, calendar: calendar)
        XCTAssertEqual(tomorrowTasks.map(\.title), ["Tomorrow", "Overdue", "Today"])
    }

    @MainActor
    func testCompletionCreatesOneFutureInstanceAndCopiesOnlyOpenChecklist() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduled = now.addingTimeInterval(-86_400)
        let done = ChecklistItem(title: "done", isDone: true, order: 0)
        let open = ChecklistItem(title: "open", order: 1)
        context.insert(done); context.insert(open)
        let task = PlannerTask(
            title: "Lecture", recurrence: .daily,
            recurrenceSeriesID: UUID(), recurrenceAnchorDate: scheduled,
            showInKanban: false, scheduled: scheduled,
            checklistItems: [done, open]
        )
        context.insert(task)
        try context.save()

        let next = try XCTUnwrap(PlannerDataService.setTaskStatus(task, status: .done, context: context, now: now))
        XCTAssertEqual(next.status, .planned)
        XCTAssertGreaterThan(try XCTUnwrap(next.scheduled), now)
        XCTAssertFalse(next.showInKanban)
        XCTAssertEqual(next.checklistItems.map(\.title), ["open"])

        _ = try PlannerDataService.setTaskStatus(task, status: .planned, context: context, now: now)
        let duplicate = try PlannerDataService.setTaskStatus(
            task,
            status: .done,
            context: context,
            now: now.addingTimeInterval(10 * 86_400)
        )
        XCTAssertEqual(duplicate?.id, next.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PlannerTask>()).count, 2)
    }

    @MainActor
    func testDraftDoesNotMutateModelAndKanbanFlagFilters() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let task = PlannerTask(title: "Original", showInKanban: false)
        context.insert(task); try context.save()
        var draft = TaskDraft(task: task)
        draft.title = "Changed"
        XCTAssertEqual(task.title, "Original")
        XCTAssertTrue(KanbanService.columns(from: [task], searchText: "", hideEmptyColumns: false).allSatisfy(\.tasks.isEmpty))

        _ = try PlannerDataService.saveTask(task, draft: draft, projects: [], context: context)
        XCTAssertEqual(task.title, "Changed")
        let outbox = try context.fetch(FetchDescriptor<SyncOutboxItem>())
        XCTAssertEqual(outbox.count, 1)
        XCTAssertEqual(outbox.first?.entityID, task.id.uuidString)
    }

    @MainActor
    func testRecurrenceRequiresScheduledOrDueDate() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let task = PlannerTask(title: "No date")
        context.insert(task); try context.save()
        var draft = TaskDraft(task: task)
        draft.recurrence = .weekly

        XCTAssertThrowsError(try PlannerDataService.saveTask(task, draft: draft, projects: [], context: context)) {
            XCTAssertEqual(($0 as? PlannerDataError)?.errorDescription, PlannerDataError.recurrenceRequiresDate.errorDescription)
        }
    }

    @MainActor
    func testEditorSessionSavesDirtyDraftOnceAndCloses() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let task = PlannerTask(title: "Original")
        context.insert(task)
        try context.save()
        let session = TaskEditorSession.open(task)
        session.draft.title = "Changed"
        var didClose = false

        XCTAssertTrue(session.saveAndClose(projects: [], context: context) { didClose = true })
        XCTAssertTrue(didClose)
        XCTAssertEqual(task.title, "Changed")
        XCTAssertEqual(try context.fetch(FetchDescriptor<SyncOutboxItem>()).count, 1)
    }

    @MainActor
    func testCleanEditorSessionClosesWithoutMutation() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let task = PlannerTask(title: "Clean")
        context.insert(task)
        try context.save()
        let session = TaskEditorSession.open(task)
        var didClose = false

        XCTAssertTrue(session.saveAndClose(projects: [], context: context) { didClose = true })
        XCTAssertTrue(didClose)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncOutboxItem>()).isEmpty)
    }

    @MainActor
    func testInvalidAndStaleEditorDraftsStayOpen() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let task = PlannerTask(title: "Original")
        context.insert(task)
        try context.save()
        let session = TaskEditorSession.open(task)
        session.draft.title = "   "
        var didClose = false

        XCTAssertFalse(session.saveAndClose(projects: [], context: context) { didClose = true })
        XCTAssertFalse(didClose)
        XCTAssertNotNil(session.errorMessage)

        session.draft.title = "Changed"
        task.updatedAt = task.updatedAt.addingTimeInterval(1)
        XCTAssertFalse(session.saveAndClose(projects: [], context: context) { didClose = true })
        XCTAssertFalse(didClose)
        XCTAssertEqual(session.errorMessage, PlannerDataError.staleDraft.errorDescription)
    }

    @MainActor
    func testEditorSessionSavesBeforeSwitchingTasks() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let first = PlannerTask(title: "First")
        let second = PlannerTask(title: "Second")
        context.insert(first)
        context.insert(second)
        try context.save()
        let session = TaskEditorSession.open(first)
        session.draft.title = "First edited"

        XCTAssertTrue(session.saveAndSwitch(to: second, projects: [], context: context))
        XCTAssertEqual(first.title, "First edited")
        XCTAssertEqual(session.task.id, second.id)
        XCTAssertEqual(session.draft.title, "Second")
        XCTAssertEqual(try context.fetch(FetchDescriptor<SyncOutboxItem>()).count, 1)
    }

    @MainActor
    func testEditorSessionDiscardClosesWithoutChangingTask() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let task = PlannerTask(title: "Original")
        context.insert(task)
        try context.save()
        let session = TaskEditorSession.open(task)
        session.draft.title = "Discarded"
        var didClose = false

        session.discardAndClose { didClose = true }
        XCTAssertTrue(didClose)
        XCTAssertEqual(task.title, "Original")
        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncOutboxItem>()).isEmpty)
    }

    @MainActor
    func testVoiceControllerAppendsPartialAndFinalResults() async {
        let provider = FakeTaskSpeechInputProvider()
        let controller = TaskVoiceInputController(provider: provider)
        var text = "Купить"
        controller.toggle(fieldID: "one", currentText: text) { text = $0 }
        for _ in 0..<100 where controller.state != .listening {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(controller.state, .listening)

        provider.emit("молоко", isFinal: false)
        for _ in 0..<100 where text != "Купить молоко" {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(text, "Купить молоко")
        XCTAssertEqual(controller.state, .listening)

        provider.emit("молоко и хлеб", isFinal: true)
        for _ in 0..<100 where text != "Купить молоко и хлеб" || controller.state != .idle {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(text, "Купить молоко и хлеб")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.activeFieldID)
    }

    @MainActor
    func testVoiceControllerPermissionFailurePreservesText() async {
        let provider = FakeTaskSpeechInputProvider()
        provider.authorization = .failure(.microphonePermissionDenied)
        let controller = TaskVoiceInputController(provider: provider)
        var text = "Сохранить меня"
        controller.toggle(fieldID: "one", currentText: text) { text = $0 }
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(text, "Сохранить меня")
        if case .failed = controller.state {
            // Expected.
        } else {
            XCTFail("Expected failed voice input state")
        }
    }

    @MainActor
    func testVoiceControllerStopsPreviousField() async {
        let provider = FakeTaskSpeechInputProvider()
        let controller = TaskVoiceInputController(provider: provider)
        controller.toggle(fieldID: "one", currentText: "") { _ in }
        await Task.yield()
        let stopsBeforeSwitch = provider.stopCount

        controller.toggle(fieldID: "two", currentText: "") { _ in }
        await Task.yield()

        XCTAssertGreaterThan(provider.stopCount, stopsBeforeSwitch)
        XCTAssertEqual(controller.activeFieldID, "two")
    }

    func testOverlapLayoutUsesSeparateLanes() {
        let task1 = PlannerTask(title: "A")
        let task2 = PlannerTask(title: "B")
        let day = CalendarDay(index: 0, date: .now, title: "", subtitle: "")
        let placements = [
            CalendarTaskPlacement(task: task1, kind: .scheduled, day: day, startMinute: 540, durationMinutes: 60, isAllDay: false),
            CalendarTaskPlacement(task: task2, kind: .scheduled, day: day, startMinute: 570, durationMinutes: 60, isAllDay: false)
        ]
        let layout = CalendarService.layoutOverlaps(placements)
        XCTAssertEqual(Set(layout.map(\.lane)).count, 2)
        XCTAssertTrue(layout.allSatisfy { $0.laneCount == 2 })
    }

    func testCalendarSplitsCrossMidnightRangeAndPreservesStartTimeWhenMoved() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let scheduled = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 23)))
        let due = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 21, hour: 1)))
        let task = PlannerTask(title: "Night", scheduled: scheduled, due: due)
        let week = CalendarService.week(containing: scheduled, calendar: calendar)

        let placements = CalendarService.placements(from: [task], searchText: "", calendar: calendar, week: week)
        XCTAssertEqual(placements.count, 2)
        XCTAssertEqual(Set(placements.map(\.id)).count, 2)
        XCTAssertEqual(placements.map(\.durationMinutes), [60, 60])

        let targetDay = try XCTUnwrap(week.days.last)
        let moved = CalendarService.moving(placements[1], toDay: targetDay, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: moved), 23)
    }

    func testCalendarExcludesCompletedAndCancelledTasks() throws {
        let scheduled = Date(timeIntervalSince1970: 1_800_000_000)
        let active = PlannerTask(title: "Active", scheduled: scheduled)
        let completed = PlannerTask(title: "Done", status: .done, scheduled: scheduled)
        let cancelled = PlannerTask(title: "Cancelled", status: .cancelled, scheduled: scheduled)
        let week = CalendarService.week(containing: scheduled)

        let placements = CalendarService.placements(
            from: [active, completed, cancelled], searchText: "", week: week
        )
        XCTAssertEqual(placements.map(\.task.id), [active.id])
    }

    @MainActor
    func testSyncUpsertInsertsNewCalendarEvent() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let dto = CalendarEventBackupDTO(
            id: id, title: "Server lesson", notes: "Room 101",
            start: start, end: start.addingTimeInterval(5_400),
            timeZoneIdentifier: "Europe/Moscow", recurrenceRawValue: "weekly",
            recurrenceEndDate: start.addingTimeInterval(90 * 86_400),
            projectID: nil, reminderRawValue: -1,
            createdAt: start, updatedAt: start
        )

        try SyncService.upsertCalendarEvent(dto, context: context)
        try context.save()

        let events = try context.fetch(FetchDescriptor<CalendarEvent>())
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.id, id)
        XCTAssertEqual(events.first?.title, "Server lesson")
    }

    @MainActor
    func testWeeklyCalendarEventProducesVirtualOccurrencesWithoutTasks() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 15)))
        let event = try CalendarEventService.create(title: "Физкультура", start: monday,
            end: monday.addingTimeInterval(7_200), timeZoneIdentifier: calendar.timeZone.identifier,
            recurrence: .weekly, reminder: .none, context: context)

        let occurrences = CalendarEventService.occurrences(for: event, from: monday,
            to: try XCTUnwrap(calendar.date(byAdding: .day, value: 22, to: monday)), calendar: calendar)
        XCTAssertEqual(occurrences.count, 4)
        XCTAssertTrue(occurrences.allSatisfy { calendar.component(.weekday, from: $0.start) == 2 })
        XCTAssertTrue(occurrences.allSatisfy { calendar.component(.hour, from: $0.start) == 15 })
        XCTAssertTrue(try context.fetch(FetchDescriptor<PlannerTask>()).isEmpty)
    }

    @MainActor
    func testCalendarEventExceptionMovesAndDeletesSingleOccurrences() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let event = try CalendarEventService.create(title: "Training", start: start,
            end: start.addingTimeInterval(3_600), recurrence: .daily, reminder: .none, context: context)
        let second = try XCTUnwrap(RecurrenceService.occurrenceDate(recurrence: .daily, anchor: start, sequence: 1))
        try CalendarEventService.updateOccurrence(of: event, on: second,
            start: second.addingTimeInterval(3_600), end: second.addingTimeInterval(7_200), context: context)
        let third = try XCTUnwrap(RecurrenceService.occurrenceDate(recurrence: .daily, anchor: start, sequence: 2))
        try CalendarEventService.deleteOccurrence(of: event, on: third, context: context)

        let storedExceptions = try context.fetch(FetchDescriptor<CalendarEventException>())
        XCTAssertEqual(storedExceptions.count, 2)
        XCTAssertTrue(storedExceptions.allSatisfy { $0.eventID == event.id })
        XCTAssertTrue(storedExceptions.contains { $0.isSkipped })
        let occurrences = CalendarEventService.occurrences(for: event, from: start,
            to: start.addingTimeInterval(4 * 86_400), exceptions: storedExceptions)
        XCTAssertEqual(occurrences.count, 3)
        XCTAssertEqual(occurrences.first(where: { $0.occurrenceDate == second })?.start, second.addingTimeInterval(3_600))
        XCTAssertFalse(occurrences.contains { $0.occurrenceDate == third })
    }

    @MainActor
    func testV1StoreMigratesToV2() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("migration.store")

        do {
            let schema = Schema(versionedSchema: PlannerSchemaV1.self)
            let configuration = ModelConfiguration("V1", schema: schema, url: url)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let task = PlannerSchemaV1.PlannerTask()
            task.title = "Before migration"
            container.mainContext.insert(task)
            try container.mainContext.save()
        }

        let schema = Schema(versionedSchema: PlannerSchemaV3.self)
        let configuration = ModelConfiguration("V2", schema: schema, url: url)
        let migrated = try ModelContainer(for: schema, migrationPlan: PlannerMigrationPlan.self, configurations: [configuration])
        let tasks = try migrated.mainContext.fetch(FetchDescriptor<PlannerTask>())
        XCTAssertEqual(tasks.first?.title, "Before migration")
        XCTAssertEqual(tasks.first?.showInKanban, true)
    }

    @MainActor
    func testV1JSONBackupImportsWithSafeDefaults() throws {
        let container = try inMemoryContainer()
        let data = Data("""
        {
          "schemaVersion": 1,
          "exportedAt": "2026-07-22T12:00:00Z",
          "tasks": [{
            "id": "00000000-0000-0000-0000-000000000001",
            "title": "Legacy",
            "notes": "",
            "status": "inbox",
            "priority": "none",
            "createdAt": "2026-07-22T12:00:00Z",
            "tagIDs": [],
            "checklistItems": [],
            "manualOrder": 0
          }],
          "projects": [],
          "tags": []
        }
        """.utf8)

        try BackupService.importData(data, context: container.mainContext)
        let task = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<PlannerTask>()).first)
        XCTAssertEqual(task.recurrence, .none)
        XCTAssertTrue(task.showInKanban)
        XCTAssertEqual(task.recurrenceSequence, 0)
    }

    @MainActor
    private func inMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: PlannerSchemaV3.self)
        return try ModelContainer(
            for: schema,
            migrationPlan: PlannerMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    private func widgetTask(title: String, priority: String, due: Date) -> PlannerWidgetTask {
        PlannerWidgetTask(
            id: UUID(),
            title: title,
            priorityRawValue: priority,
            scheduled: nil,
            due: due,
            createdAt: due,
            projectTitle: nil,
            projectColorRawValue: nil
        )
    }
}

@MainActor
private final class FakeTaskSpeechInputProvider: TaskSpeechInputProviding {
    var authorization: Result<Void, TaskVoiceInputError> = .success(())
    private(set) var stopCount = 0
    private var onResult: ((String, Bool) -> Void)?
    private var onFailure: ((TaskVoiceInputError) -> Void)?

    func requestAuthorization() async -> Result<Void, TaskVoiceInputError> {
        authorization
    }

    func start(
        locale: Locale,
        onResult: @escaping (String, Bool) -> Void,
        onFailure: @escaping (TaskVoiceInputError) -> Void
    ) throws {
        XCTAssertEqual(locale.identifier, "ru-RU")
        self.onResult = onResult
        self.onFailure = onFailure
    }

    func stop() {
        stopCount += 1
    }

    func emit(_ text: String, isFinal: Bool) {
        onResult?(text, isFinal)
    }

    func fail(_ error: TaskVoiceInputError) {
        onFailure?(error)
    }
}
