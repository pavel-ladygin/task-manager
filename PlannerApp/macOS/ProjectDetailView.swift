import SwiftData
import SwiftUI

#if os(macOS)
struct ProjectDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let project: Project
    @State private var editingProject: Project
    @State private var draft: ProjectDraft
    @State private var errorMessage: String?
    @State private var pendingProject: Project?
    @State private var isSwitchConfirmationPresented = false

    init(project: Project) {
        self.project = project
        _editingProject = State(initialValue: project)
        _draft = State(initialValue: ProjectDraft(project: project))
    }

    private var isDirty: Bool { draft != ProjectDraft(project: editingProject) }

    var body: some View {
        Form {
            Section("Проект") {
                TextField("Название", text: $draft.title)
                Picker("Статус", selection: $draft.status) {
                    ForEach(ProjectStatus.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Цвет", selection: $draft.color) {
                    ForEach(ProjectColorPreset.allCases) { color in
                        HStack { ProjectColorSwatch(preset: color); Text(color.displayName) }.tag(color)
                    }
                }
            }
            Section("Срок") { ProjectOptionalDatePicker(date: $draft.deadline) }
            Section("Заметки") { TextEditor(text: $draft.notes).frame(minHeight: 140) }
            Section("Метаданные") {
                LabeledContent("Создан", value: editingProject.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Обновлен", value: editingProject.updatedAt.formatted(date: .abbreviated, time: .shortened))
                if isDirty { Label("Есть несохранённые изменения", systemImage: "pencil.circle") }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(PlannerTheme.windowBackground)
        .tint(PlannerTheme.accent)
        .navigationTitle("Параметры проекта")
        .toolbar {
            ToolbarItemGroup {
                Button("Отмена") { draft = ProjectDraft(project: project) }.disabled(!isDirty)
                Button("Сохранить") { _ = save() }.keyboardShortcut("s", modifiers: .command).disabled(!isDirty)
            }
        }
        .onChange(of: project.id) { _, _ in
            if isDirty {
                pendingProject = project
                isSwitchConfirmationPresented = true
            } else {
                adopt(project)
            }
        }
        .confirmationDialog("Сохранить изменения перед переходом?", isPresented: $isSwitchConfirmationPresented) {
            Button("Сохранить") {
                if save(), let pendingProject { adopt(pendingProject) }
            }
            Button("Отбросить", role: .destructive) {
                if let pendingProject { adopt(pendingProject) }
            }
            Button("Остаться", role: .cancel) { pendingProject = nil }
        }
        .alert("Ошибка планировщика", isPresented: errorBinding) {
            Button("ОК", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
    @discardableResult
    @MainActor
    private func save() -> Bool {
        do {
            try PlannerDataService.saveProject(editingProject, draft: draft, context: modelContext)
            draft = ProjectDraft(project: editingProject)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
    private func adopt(_ project: Project) {
        editingProject = project
        draft = ProjectDraft(project: project)
        pendingProject = nil
    }
}

private struct ProjectOptionalDatePicker: View {
    @Binding var date: Date?
    var body: some View {
        Toggle("Есть срок", isOn: Binding(get: { date != nil }, set: { date = $0 ? (date ?? .now) : nil }))
        if date != nil {
            DatePicker("Срок", selection: Binding(get: { date ?? .now }, set: { date = $0 }), displayedComponents: .date)
        }
    }
}

private struct ProjectColorSwatch: View {
    let preset: ProjectColorPreset
    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(PlannerTheme.projectGradient(preset, opacity: 0.9))
            .frame(width: 28, height: 18)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(PlannerTheme.projectAccent(preset).opacity(0.75), lineWidth: 1))
    }
}
#endif
