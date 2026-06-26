import AppIntents
import WidgetKit

// MARK: - Employee entity (widget configuration target)

/// A selectable AI employee surfaced in the widget's configuration UI
/// (long-press the widget → "ウィジェットを編集" → 社員). Backed by the roster the
/// app publishes to the App Group via `SharedStore`.
struct EmployeeEntity: AppEntity, Identifiable {
    let id: String
    let name: String
    let emoji: String
    let roleTitle: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "社員" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(emoji) \(name)", subtitle: "\(roleTitle)")
    }

    static var defaultQuery = EmployeeQuery()

    static func from(_ s: EmployeeSnapshot) -> EmployeeEntity {
        EmployeeEntity(id: s.id, name: s.name, emoji: s.emoji, roleTitle: s.roleTitle)
    }

    /// Sentinel shown in the picker before the app has published a roster, so the
    /// configuration UI is never blank. Its id matches no real employee, so the
    /// widget provider falls back to the active employee when it's selected.
    static let openAppPrompt = EmployeeEntity(
        id: "__open_app__", name: "アプリを開いて社員を読み込む", emoji: "📲", roleTitle: "未取得")
}

/// Resolves employee entities from the shared snapshot for the configuration picker.
struct EmployeeQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [EmployeeEntity] {
        let all = SharedStore.snapshot().employees
        return identifiers.map { id in
            all.first { $0.id == id }.map(EmployeeEntity.from)
                ?? (id == EmployeeEntity.openAppPrompt.id ? EmployeeEntity.openAppPrompt : nil)
        }.compactMap { $0 }
    }

    func suggestedEntities() async throws -> [EmployeeEntity] {
        let roster = SharedStore.snapshot().employees
        return roster.isEmpty ? [EmployeeEntity.openAppPrompt] : roster.map(EmployeeEntity.from)
    }
}

// MARK: - Configuration intent

/// Per-instance widget configuration: which 社員 this widget shows. When left
/// unset, the widget tracks whichever employee is currently active in the app.
struct SelectEmployeeIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "社員を選択"
    static var description = IntentDescription("ウィジェットに表示するAI社員を選びます。未選択のときは、アプリで対応中の社員を表示します。")

    @Parameter(title: "社員")
    var employee: EmployeeEntity?

    init() {}
    init(employee: EmployeeEntity?) { self.employee = employee }
}
