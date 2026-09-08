import SwiftUI

struct HabitRitualCard: View {
    @EnvironmentObject private var habitStore: HabitStore
    @State private var showsRitual = false

    var body: some View {
        Button { showsRitual = true } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(PlannerTheme.accentSoft, lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(PlannerTheme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(habitStore.completedTodayCount)/\(habitStore.habits.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(PlannerTheme.secondaryText)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(habitStore.habits.isEmpty ? "Начать ритуал" : "Ваш ритуал")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(PlannerTheme.secondaryText)
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(PlannerTheme.accent)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showsRitual) {
            NavigationStack { HabitRitualSheet() }
        }
    }

    private var progress: Double {
        guard !habitStore.habits.isEmpty else { return 0 }
        return Double(habitStore.completedTodayCount) / Double(habitStore.habits.count)
    }

    private var subtitle: String {
        if habitStore.habits.isEmpty { return "Создайте первую привычку" }
        if habitStore.completedTodayCount == habitStore.habits.count { return "Все привычки на сегодня выполнены" }
        let remaining = habitStore.habits.count - habitStore.completedTodayCount
        return "Осталось: \(remaining) \(remaining == 1 ? "привычка" : "привычки")"
    }
}

private struct HabitRitualSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var habitStore: HabitStore
    @State private var selectedHabit: Habit?
    @State private var showsManagement = false
    @State private var earnedMilestone: HabitMilestone?

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ритуал дня").font(.headline)
                        Text("\(habitStore.completedTodayCount) из \(habitStore.habits.count) выполнено")
                            .font(.caption)
                            .foregroundStyle(PlannerTheme.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "flame.fill")
                        .foregroundStyle(PlannerTheme.warning)
                }
            }

            if habitStore.habits.isEmpty {
                ContentUnavailableView("Нет привычек", systemImage: "sparkles", description: Text("Создайте первую привычку для ежедневного ритуала."))
            } else {
                Section("Сегодня") {
                    ForEach(habitStore.habits) { habit in
                        HabitCheckRow(habit: habit) {
                            earnedMilestone = habitStore.toggle(habit)
                        } edit: {
                            selectedHabit = habit
                        }
                    }
                }
            }

            Section {
                Button("Управлять привычками", systemImage: "slider.horizontal.3") {
                    showsManagement = true
                }
            }
        }
        .navigationTitle("Ваш ритуал")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Готово") { dismiss() }
            }
        }
        .navigationDestination(isPresented: $showsManagement) { HabitManagementView() }
        .sheet(item: $selectedHabit) { habit in
            HabitEditorView(habit: habit)
        }
        .alert(item: $earnedMilestone) { milestone in
            Alert(
                title: Text("Награда открыта"),
                message: Text("\(milestone.title) — \(milestone.days) дней подряд!"),
                dismissButton: .default(Text("Продолжить"))
            )
        }
    }
}

struct HabitManagementView: View {
    @EnvironmentObject private var habitStore: HabitStore
    @State private var editorHabit: Habit?
    @State private var showsNewHabit = false

    var body: some View {
        List {
            Section {
                HabitSummaryView()
            }

            Section("Привычки") {
                ForEach(habitStore.habits) { habit in
                    Button { editorHabit = habit } label: {
                        HStack(spacing: 12) {
                            Image(systemName: habit.icon)
                                .font(.title3)
                                .foregroundStyle(habit.color.color)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(habit.title).foregroundStyle(.primary)
                                Text("🔥 \(habitStore.currentStreak(for: habit)) дней подряд")
                                    .font(.caption)
                                    .foregroundStyle(PlannerTheme.secondaryText)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(PlannerTheme.secondaryText)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { indexSet in
                    indexSet.map { habitStore.habits[$0] }.forEach(habitStore.delete)
                }
            }

            Section("Награды") {
                ForEach(HabitMilestone.all) { milestone in
                    let earned = habitStore.habits.contains { habitStore.currentStreak(for: $0) >= milestone.days }
                    Label(milestone.title, systemImage: milestone.symbol)
                        .foregroundStyle(earned ? PlannerTheme.warning : PlannerTheme.secondaryText)
                }
            }
        }
        .navigationTitle("Привычки")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Новая привычка", systemImage: "plus") { showsNewHabit = true }
            }
        }
        .sheet(isPresented: $showsNewHabit) { HabitEditorView() }
        .sheet(item: $editorHabit) { habit in HabitEditorView(habit: habit) }
    }
}

private struct HabitSummaryView: View {
    @EnvironmentObject private var habitStore: HabitStore

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(PlannerTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Ваш ритм")
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(PlannerTheme.secondaryText)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        guard let next = HabitMilestone.all.first(where: { milestone in
            !habitStore.habits.contains { habitStore.currentStreak(for: $0) >= milestone.days }
        }) else { return "Все награды открыты" }
        return "Следующая награда: «\(next.title)»"
    }
}

private struct HabitCheckRow: View {
    @EnvironmentObject private var habitStore: HabitStore
    let habit: Habit
    let toggle: () -> Void
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: habitStore.isCompleted(habit, on: .now) ? "checkmark.circle.fill" : habit.icon)
                    .font(.title3)
                    .foregroundStyle(habitStore.isCompleted(habit, on: .now) ? habit.color.color : habit.color.color)
                    .frame(width: 32, height: 32)
                    .background(habit.color.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(habit.title)
                Text("🔥 \(habitStore.currentStreak(for: habit)) дней подряд")
                    .font(.caption)
                    .foregroundStyle(PlannerTheme.secondaryText)
            }
            Spacer()
            Button(action: edit) {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(PlannerTheme.secondaryText)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct HabitEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var habitStore: HabitStore
    let habit: Habit?
    @State private var title: String
    @State private var icon: String
    @State private var color: HabitColor

    private let icons = ["drop.fill", "figure.walk", "book.fill", "brain.head.profile", "leaf.fill", "bed.double.fill", "fork.knife", "figure.strengthtraining.traditional"]

    init(habit: Habit? = nil) {
        self.habit = habit
        _title = State(initialValue: habit?.title ?? "")
        _icon = State(initialValue: habit?.icon ?? "sparkles")
        _color = State(initialValue: habit?.color ?? .ocean)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Название") { TextField("Например, Утренняя прогулка", text: $title) }
                Section("Иконка") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(icons, id: \.self) { option in
                            Button { icon = option } label: {
                                Image(systemName: option)
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .foregroundStyle(icon == option ? .white : color.color)
                                    .background(icon == option ? color.color : color.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 3)
                }
                Section("Цвет") {
                    HStack(spacing: 14) {
                        ForEach(HabitColor.allCases) { option in
                            Button { color = option } label: {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if color == option {
                                            Image(systemName: "checkmark")
                                                .font(.caption.bold())
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .overlay(Circle().strokeBorder(Color.white.opacity(color == option ? 0.65 : 0), lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.title)
                            .accessibilityAddTraits(color == option ? .isSelected : [])
                        }
                    }
                }
                if let habit {
                    Section {
                        Button("Удалить привычку", role: .destructive) {
                            habitStore.delete(habit)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(habit == nil ? "Новая привычка" : "Изменить привычку")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        if let habit { habitStore.update(habit, title: title, icon: icon, color: color) }
                        else { habitStore.create(title: title, icon: icon, color: color) }
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
