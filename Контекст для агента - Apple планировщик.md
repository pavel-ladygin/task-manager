---
type: project-context
area: planning
tags:
  - codex
  - planner
  - swiftui
  - obsidian
created: 2026-06-28
---
# Контекст для агента: Apple-планировщик задач

Нужно сделать персональный планировщик задач под Apple-экосистему. За основу берется не весь Obsidian vault, а только то, как сейчас устроено планирование: задачи, списки, канбан, календарь и проекты.

Цель первого этапа: стабильное локальное macOS-приложение для базового планирования задач.

Не нужно в первом варианте переносить контакты, дни рождения, MediaVault, фильмы, медицинские заметки, погоду, Pomodoro, time tracking, распознавание естественного языка, Google/Microsoft Calendar и сложные markdown-интеграции.

## Техническая концепция

Приложение должно быть Apple-native:

```text
SwiftUI Multiplatform
SwiftData
JSON export/import
UserNotifications позже
Backend sync через собственный сервер позже
```

Почему так:

- SwiftUI позволяет вести общий проект под macOS и iOS.
- SwiftData подходит для локального хранения задач.
- JSON export/import нужен как резервная копия на раннем этапе.
- UserNotifications нужны позже для напоминаний.
- Backend sync нужен позже для синхронизации Mac и iPhone через собственный сервер без зависимости от платной Apple Developer Program.
- Xcode используется как сборщик и инструмент подписи, основная разработка может идти в Cursor/Codex.

Первый этап:

```text
macOS first
```

Причины:

- проще тестировать;
- быстрее разрабатывать;
- не нужно постоянно ставить приложение на iPhone;
- можно сначала обкатать модель данных, UX, списки, канбан и календарь.

После стабилизации macOS-версии добавить iOS-интерфейс на той же кодовой базе:

```text
shared core + separate platform UI where needed
```

Не писать два отдельных приложения.

## Текущий Obsidian-планировщик

Планировщик сейчас находится в:

```text
Planning/
```

Основные файлы:

```text
Planning/Планировщик.md
Planning/Tasks/*.md
Planning/Projects/*.md
Planning/Views/Tasks.base
Planning/Views/Kanban.base
Planning/Views/Calendar.base
Planning/Views/Agenda.base
Planning/Views/Daily.base
Planning/Views/Project.base
```

Задачи сейчас лежат отдельными markdown-файлами:

```text
Planning/Tasks/2026-06-16 экзамен ИИ.md
Planning/Tasks/2026-06-19 скинуть маме за сплит 914.md
```

Каждая задача имеет YAML frontmatter и markdown-тело.

Пример:

```yaml
---
title: экзамен ИИ
status: done
priority: high
scheduled: 2026-06-19T09:00
created: 2026-06-16T00:53:03.828+03:00
modified: 2026-06-19T10:20:42.908+03:00
type: task
tags:
  - planning
completed: 2026-06-19
tasknotes_manual_order: tnvririririo
---
```

Тело задачи:

```markdown
# экзамен ИИ

## Описание

## Чеклист

- [ ]

## Заметки
```

В новом приложении не нужно хранить задачи markdown-файлами. Это только источник понимания текущей модели. В приложении данные должны храниться через SwiftData.

## Функциональная модель

### Задача

Модель `PlannerTask`:

```text
id
title
notes
status
priority
scheduled
due
createdAt
updatedAt
completedAt
project
tags
checklistItems
manualOrder
```

Минимально обязательные поля:

```text
title
status
priority
scheduled
due
createdAt
updatedAt
completedAt
project
notes
```

### Статусы

Поддержать базовые статусы:

```text
inbox
planned
in-progress
done
cancelled
```

Смысл:

| Статус | Смысл |
|---|---|
| `inbox` | Новая неразобранная задача |
| `planned` | Запланированная задача |
| `in-progress` | Задача в работе |
| `done` | Выполнена |
| `cancelled` | Отменена |

В будущем можно добавить:

```text
backlog
waiting
```

Но в первом MVP они не обязательны.

### Приоритеты

Поддержать:

```text
none
low
medium
high
urgent
```

Сортировка:

```text
urgent > high > medium > low > none
```

### Проект

Проекты сейчас лежат в:

```text
Planning/Projects/
```

Пример:

```yaml
---
type: project
area: learning
status: active
title: ВУЗ
deadline:
tags:
  - project
  - university
---
```

Модель `Project`:

```text
id
title
status
deadline
notes
createdAt
updatedAt
```

Страница проекта должна показывать задачи этого проекта.

### Чеклист

У задачи может быть простой чеклист:

```text
id
title
isDone
order
```

Сложные вложенные подзадачи не нужны в первом MVP.

## Представления

Главный экран сейчас находится в `Planning/Планировщик.md` и содержит:

```text
Входящие
Сегодня
Канбан
Эта неделя
По проектам
Эффективность
```

В приложении сделать нормальный интерфейс:

- слева sidebar;
- по центру список/канбан/календарь;
- справа детали выбранной задачи.

Разделы sidebar:

```text
Inbox
Today
Upcoming
Kanban
Calendar
Projects
Completed
Settings
```

## Списки задач

Логика списков берется из `Planning/Views/Tasks.base`.

### Inbox

Фильтр:

```text
status == inbox
```

Сортировка:

```text
priority desc
createdAt asc
```

### Today

Показывает активные задачи, у которых `scheduled` или `due` сегодня или раньше:

```text
status != done
status != cancelled
and (
  scheduled <= today
  or due <= today
)
```

Просроченные задачи тоже должны попадать в Today, пока они не закрыты.

Сортировка:

```text
priority desc
due asc
scheduled asc
```

### Upcoming / Эта неделя

Показывает активные задачи на ближайшие 7 дней:

```text
status != done
status != cancelled
and (
  scheduled between today and today + 7 days
  or due between today and today + 7 days
)
```

Сортировка:

```text
scheduled asc
priority desc
```

### Completed

Показывает выполненные и отмененные задачи:

```text
status == done
or status == cancelled
```

Сортировка:

```text
completedAt desc
updatedAt desc
```

### By Project

Показывает активные задачи, сгруппированные по проекту:

```text
status != done
status != cancelled
```

Группировка:

```text
project
```

## Канбан

Текущий канбан описан в:

```text
Planning/Views/Kanban.base
```

Сейчас он показывает:

```text
planned
in-progress
done
```

Группировка:

```text
status
```

Сортировка:

```text
tasknotes_manual_order desc
```

В приложении нужен канбан:

- колонки по статусам;
- карточки задач внутри колонок;
- drag-and-drop между колонками;
- при переносе карточки меняется `status`;
- ручной порядок карточек сохраняется в `manualOrder`;
- пустые колонки можно скрывать настройкой.

Колонки первого варианта:

```text
Inbox
Planned
In Progress
Done
Cancelled
```

Карточка задачи показывает:

- название;
- приоритет;
- `scheduled`;
- `due`;
- проект.

## Календарь

Текущий календарь описан в:

```text
Planning/Views/Calendar.base
```

Настройки текущего календаря:

```text
showScheduled: true
showDue: true
calendarView: timeGridWeek
firstDay: 1
slotDuration: 00:30:00
timeFormat: 24
nowIndicator: true
weekNumbers: true
```

В приложении нужен базовый календарь:

- недельный вид;
- понедельник - первый день недели;
- 24-часовой формат;
- шаг сетки 30 минут;
- показывать задачи по `scheduled`;
- показывать дедлайны по `due`;
- задачи с временем показывать в сетке времени;
- задачи без времени показывать как задачи на день;
- клик по задаче открывает детали;
- перенос задачи в календаре меняет дату/время `scheduled`.

На первом этапе достаточно недельного календаря. День и месяц можно добавить позже.

## Agenda / Upcoming

Текущая повестка описана в:

```text
Planning/Views/Agenda.base
```

Она показывает активные задачи списком:

```text
status != done
status != cancelled
```

В приложении `Upcoming` можно сделать как agenda-список:

```text
Сегодня
Завтра
Эта неделя
Позже
Без даты
```

## Детали задачи

При выборе задачи справа открывается панель редактирования.

Поля:

```text
title
status
priority
scheduled
due
project
notes
checklist
createdAt
updatedAt
completedAt
```

Нужно уметь:

- создать задачу;
- отредактировать задачу;
- удалить задачу;
- отметить как `done`;
- отменить задачу;
- поменять проект;
- поменять даты;
- добавить заметку;
- добавить пункты чеклиста.

## Быстрое создание задачи

Распознавание естественного языка не нужно.

Нужна простая форма:

```text
Название
Проект
Статус
Приоритет
Дата scheduled
Дата due
Описание
```

Дополнительно можно сделать компактное поле `New task`, которое создает задачу только по названию, а остальные поля пользователь заполняет потом.

## Архитектура проекта

Рекомендуемая структура:

```text
PlannerApp
├── Core
│   ├── Models
│   │   ├── PlannerTask
│   │   ├── Project
│   │   ├── Tag
│   │   ├── ChecklistItem
│   │   └── AppSettings
│   │
│   ├── Services
│   │   ├── TaskService
│   │   ├── ProjectService
│   │   ├── SearchService
│   │   └── ImportExportService
│   │
│   └── Utils
│       ├── DateUtils
│       ├── SortUtils
│       └── Validation
│
├── Features
│   ├── Today
│   ├── Inbox
│   ├── Upcoming
│   ├── Projects
│   ├── Kanban
│   ├── Calendar
│   ├── Search
│   └── Settings
│
├── macOS
│   ├── MacMainView
│   ├── MacSidebar
│   ├── MacMenuCommands
│   └── MacTaskDetailView
│
└── iOS
    ├── IOSMainView
    ├── IOSTabView
    └── IOSTaskDetailView
```

Принцип:

```text
одно ядро данных и логики
+
два интерфейса: macOS и iOS
```

Общие части:

- модели;
- SwiftData-схема;
- логика создания задач;
- фильтры списков;
- сортировка;
- поиск;
- импорт/экспорт;
- настройки.

Раздельные части:

- навигация;
- layout;
- меню;
- хоткеи;
- platform-specific UI.

## Хранение данных

Основное хранилище:

```text
SwiftData
```

Сущности первого этапа:

```text
PlannerTask
Project
Tag
ChecklistItem
AppSettings
```

Данные должны храниться локально и не пропадать после перезапуска приложения.

Для страховки обязательно добавить:

```text
Export to JSON
Import from JSON
```

Это нужно из-за возможных миграций модели, ошибок SwiftData или сброса приложения во время разработки.

JSON backup должен включать:

- задачи;
- проекты;
- теги;
- настройки;
- версию схемы.

## Будущие технические этапы

Эти вещи важны для полноценного проекта, но не должны блокировать первый MVP.

### iOS

После стабильной macOS-версии добавить iOS-интерфейс:

- общий Core слой оставить тем же;
- адаптировать навигацию под TabView/NavigationStack;
- не дублировать бизнес-логику;
- проверить установку на iPhone через Xcode.

### Уведомления

Позже использовать:

```text
UserNotifications
```

Нужно будет реализовать:

- запрос разрешения;
- уведомление в точное время задачи;
- опциональное напоминание заранее;
- пересоздание уведомлений при изменении задачи;
- отмену уведомлений при выполнении/удалении задачи.

Не делать уведомления первым этапом. Сначала модели, база, UI, списки, канбан и календарь.

### Синхронизация

Целевая синхронизация:

```text
Backend sync через собственный сервер
```

Требования на будущее:

- автоматическая синхронизация;
- пользователь не нажимает Sync вручную;
- приложение работает офлайн;
- конфликты решаются предсказуемо;
- сначала локальная SwiftData-база;
- затем JSON backup;
- только потом backend sync.

Не начинать проект с backend sync. CloudKit/iCloud не является целевым вариантом синхронизации для этого проекта без отдельного явного решения пользователя.

## Xcode, подпись и установка

Основная разработка:

```text
Cursor / Codex
```

Xcode использовать для:

- создания исходного Multiplatform-проекта;
- настройки Signing & Capabilities;
- запуска на Mac;
- запуска на iPhone;
- включения notifications позже.

Для личного использования на iPhone можно ставить приложение бесплатно через:

```text
Xcode + бесплатный Apple ID
```

Ограничения бесплатной подписи:

- приложение обычно нужно переподписывать примерно раз в 7 дней;
- нужно открыть проект в Xcode, подключить iPhone и нажать Run;
- если Bundle Identifier не меняется, данные приложения обычно сохраняются;
- данные могут слететь, если удалить приложение, поменять Bundle ID или установить приложение как новое.

Зафиксировать Bundle Identifier:

```text
com.pavel.planner
```

Не менять его после первой установки.

Риски бесплатной подписи:

```text
Provisioning profile expired
No signing certificate
Failed to codesign
Developer Mode disabled
Device not trusted
Bundle identifier conflict
```

Как снижать риски:

- использовать один Apple ID;
- не менять Bundle Identifier;
- включить Developer Mode на iPhone;
- доверять Mac/iPhone при подключении;
- держать проект в Git;
- регулярно делать JSON export данных;
- не удалять приложение с iPhone без резервной копии.

Для macOS все проще:

- можно запускать приложение прямо из Xcode;
- можно собрать `.app`;
- можно положить `.app` в Applications;
- App Store не нужен;
- платный Apple Developer аккаунт не нужен для личного использования.

## Что не нужно делать в первом варианте

Не добавлять:

- контакты;
- дни рождения;
- MediaVault;
- фильмы/сериалы;
- медицинские заметки;
- погоду;
- Open-Meteo;
- Pomodoro;
- time tracking;
- Google Calendar;
- Microsoft Calendar;
- распознавание русского естественного языка;
- импорт всего Obsidian vault;
- сложные markdown-интеграции;
- backend sync;
- CloudKit/iCloud sync;
- уведомления;
- полноценный iOS UI.

Backend sync, уведомления и iOS важны для будущего, но не входят в первый локальный macOS MVP. CloudKit/iCloud sync не является целевой синхронизацией проекта без отдельного явного решения.

## MVP

Первый MVP должен включать:

- macOS SwiftUI-приложение;
- SwiftData-хранение;
- модели задач, проектов, тегов и чеклиста;
- создание/редактирование/удаление задач;
- статусы;
- приоритеты;
- проекты;
- Inbox;
- Today;
- Upcoming;
- Completed;
- Kanban;
- Calendar week view;
- detail panel задачи;
- базовый поиск по названию/заметкам;
- JSON export/import.

## Приемка MVP

MVP готов, если:

- приложение запускается на macOS;
- можно создать задачу;
- задача сохраняется после перезапуска;
- можно назначить статус, приоритет, проект, `scheduled` и `due`;
- Today показывает сегодняшние и просроченные активные задачи;
- Upcoming показывает задачи на ближайшие 7 дней;
- Completed показывает закрытые задачи;
- Kanban позволяет переносить задачу между статусами;
- Calendar показывает задачи на неделе;
- изменение даты в задаче отражается в календаре;
- страница проекта показывает задачи проекта;
- JSON export создает резервную копию;
- JSON import восстанавливает данные.

## Итоговая стратегия разработки

```text
1. Создать SwiftUI Multiplatform App
2. Сделать локальную macOS-версию
3. Добавить SwiftData-модели
4. Реализовать списки задач
5. Реализовать detail panel
6. Реализовать проекты
7. Реализовать канбан
8. Реализовать недельный календарь
9. Добавить JSON backup
10. Довести UX Mac-версии
11. Позже добавить iOS interface
12. Позже добавить уведомления
13. Позже добавить backend sync через собственный сервер
```

Критически важно:

```text
не начинать с backend sync, уведомлений и iOS-подписи
```

Сначала нужно сделать стабильное локальное приложение на Mac.

## Короткий промпт для агента

Сделай персональный Apple-native планировщик задач на SwiftUI Multiplatform + SwiftData. За функциональную основу возьми только планировщик из моего Obsidian: задачи с полями `title/status/priority/scheduled/due/project/notes/checklist`, списки Inbox/Today/Upcoming/Completed, канбан по статусам, недельный календарь и проекты. Первый этап - локальный macOS MVP с JSON export/import. Не добавляй контакты, дни рождения, медиа, погоду, Pomodoro, time tracking, распознавание естественного языка, Google/Microsoft Calendar и сложные markdown-интеграции. iOS, UserNotifications и backend sync описать в архитектуре как будущие этапы, но не начинать с них. Для синхронизации использовать собственный backend-сервер, а не CloudKit/iCloud.
