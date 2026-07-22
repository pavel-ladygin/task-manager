import Foundation
import UserNotifications

enum NotificationService {
    private static let scheduledSuffix = "scheduled"
    private static let dueSuffix = "due"

    static func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        )
    }

    static func authorizationStatusDescription() async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return description(for: settings.authorizationStatus)
    }

    static func scheduleNotifications(for task: PlannerTask, settings: AppSettings) {
        cancelNotifications(for: task)

        guard TaskListService.isActive(task) else {
            return
        }

        if let scheduled = task.scheduled {
            scheduleNotification(
                for: task,
                date: scheduled,
                leadMinutes: settings.defaultReminderLeadMinutes,
                kind: scheduledSuffix,
                title: "Запланированная задача"
            )
        }

        if let due = task.due {
            scheduleNotification(
                for: task,
                date: due,
                leadMinutes: settings.defaultReminderLeadMinutes,
                kind: dueSuffix,
                title: "Срок задачи"
            )
        }
    }

    static func cancelNotifications(for task: PlannerTask) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: notificationIdentifiers(for: task)
        )
    }

    static func rescheduleNotifications(for task: PlannerTask, settings: AppSettings) {
        cancelNotifications(for: task)
        scheduleNotifications(for: task, settings: settings)
    }

    private static func scheduleNotification(
        for task: PlannerTask,
        date: Date,
        leadMinutes: Int,
        kind: String,
        title: String
    ) {
        guard let triggerDate = triggerDate(for: date, leadMinutes: leadMinutes) else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = task.title
        content.sound = .default

        let triggerComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: triggerDate
        )
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: triggerComponents,
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: notificationIdentifier(for: task, kind: kind),
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request)
    }

    private static func triggerDate(for date: Date, leadMinutes: Int) -> Date? {
        let leadDate = Calendar.current.date(
            byAdding: .minute,
            value: -max(0, leadMinutes),
            to: date
        ) ?? date

        if leadDate > .now {
            return leadDate
        }

        return date > .now ? date : nil
    }

    private static func notificationIdentifiers(for task: PlannerTask) -> [String] {
        [
            notificationIdentifier(for: task, kind: scheduledSuffix),
            notificationIdentifier(for: task, kind: dueSuffix)
        ]
    }

    private static func notificationIdentifier(for task: PlannerTask, kind: String) -> String {
        "planner.task.\(task.id.uuidString).\(kind)"
    }

    private static func description(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            "Разрешены"
        case .denied:
            "Запрещены"
        case .notDetermined:
            "Не запрошены"
        case .provisional:
            "Временное разрешение"
        case .ephemeral:
            "Временные"
        @unknown default:
            "Неизвестно"
        }
    }
}
