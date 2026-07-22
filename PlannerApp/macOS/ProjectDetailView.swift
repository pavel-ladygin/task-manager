import SwiftData
import SwiftUI

#if os(macOS)
struct ProjectDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var project: Project

    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Проект") {
                TextField("Название", text: $project.title)
                    .onChange(of: project.title) { _, _ in saveProjectChanges() }

                Picker("Статус", selection: statusBinding) {
                    ForEach(ProjectStatus.allCases) { status in
                        Text(status.displayName).tag(status)
                    }
                }
            }

            Section("Заметки") {
                TextEditor(text: $project.notes)
                    .frame(minHeight: 140)
                    .onChange(of: project.notes) { _, _ in saveProjectChanges() }
            }

            Section("Метаданные") {
                LabeledContent("Создан", value: project.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Обновлен", value: project.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(PlannerTheme.windowBackground)
        .tint(PlannerTheme.accent)
        .navigationTitle("Параметры проекта")
        .alert("Ошибка планировщика", isPresented: errorBinding) {
            Button("ОК", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var statusBinding: Binding<ProjectStatus> {
        Binding(
            get: { project.status },
            set: { newValue in
                project.status = newValue
                saveProjectChanges()
            }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func saveProjectChanges() {
        do {
            try PlannerDataService.markProjectUpdated(project, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
