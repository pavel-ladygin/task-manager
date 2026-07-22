import SwiftData
import SwiftUI

@main
struct PlannerApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            let schema = Schema(PlannerSchema.models)
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Не удалось создать контейнер SwiftData: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            MacMainView()
            #else
            IOSMainView()
            #endif
        }
        .modelContainer(modelContainer)
        #if os(macOS)
        .commands {
            PlannerCommands()
        }
        #endif
    }
}

#if os(macOS)
struct PlannerCommands: Commands {
    @FocusedValue(\.plannerCommandActions) private var plannerCommandActions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Новая задача") {
                plannerCommandActions?.focusQuickAdd()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(plannerCommandActions == nil)
        }

        CommandMenu("Планировщик") {
            Button("Поиск") {
                plannerCommandActions?.focusSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(plannerCommandActions == nil)

            Button("Показать/скрыть инспектор") {
                plannerCommandActions?.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(plannerCommandActions == nil)

            Divider()

            Button("Отметить выполненной") {
                plannerCommandActions?.markSelectedTaskDone()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(plannerCommandActions?.canMarkSelectedTaskDone != true)
        }
    }
}
#endif
