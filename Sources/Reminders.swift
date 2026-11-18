import EventKit
import Foundation

struct ReminderDay: Codable, Equatable {
    let year: Int
    let month: Int
    let day: Int

    init?(iso: String) {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [4, 2, 2], let year = Int(parts[0]),
              let month = Int(parts[1]), let day = Int(parts[2]), year > 0 else { return nil }
        self.year = year
        self.month = month
        self.day = day
        guard let date, Self(date) == self else { return nil }
    }

    init(_ date: Date) {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 1
        month = components.month ?? 1
        day = components.day ?? 1
    }

    var components: DateComponents {
        DateComponents(calendar: Calendar(identifier: .gregorian), year: year, month: month, day: day)
    }

    var date: Date? { components.date }

    func matchesPrintedDate(in text: String?) -> Bool {
        let fields = text?.split(whereSeparator: { !$0.isASCII || !$0.isNumber }) ?? []
        return fields.map { Int($0) } == [year, month, day]
    }
}

struct PaperTodo: Codable, Identifiable {
    var id = UUID()
    let title: String
    let dueText: String?
    let date: ReminderDay?
    let anchor: String?
    let box: ReviewBox?
    var delivery: ReminderDelivery?
}

struct ReminderList: Identifiable {
    let id: String
    let name: String
    let account: String
    let isDefault: Bool

    var label: String { account.isEmpty ? name : "\(name) · \(account)" }
}

struct ReminderDelivery: Codable {
    let title: String
    let date: ReminderDay?
    let listID: String
    let listLabel: String
    var sent = false
}

@MainActor
protocol ReminderService {
    func lists() async throws -> [ReminderList]
    func contains(_ todo: UUID, in listID: String) async throws -> Bool
    func add(_ delivery: ReminderDelivery, for todo: UUID) throws
}

@MainActor
final class AppleReminders: ReminderService {
    private lazy var store = EKEventStore()

    func lists() async throws -> [ReminderList] {
        if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
            _ = try await store.requestFullAccessToReminders()
            store.reset()
        }
        try requireAccess()
        let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
        let lists = store.calendars(for: .reminder).filter(\.allowsContentModifications)
            .map { ReminderList(id: $0.calendarIdentifier, name: $0.title,
                                account: $0.source?.title ?? "", isDefault: $0.calendarIdentifier == defaultID) }
        return lists.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    func contains(_ todo: UUID, in listID: String) async throws -> Bool {
        try requireAccess()
        guard let list = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == listID }) else {
            return false
        }
        let predicate = store.predicateForReminders(in: [list])
        let marker = originMarker(todo)
        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(throwing: AppFailure.message("无法核对上次添加结果，请稍后再试。"))
                    return
                }
                continuation.resume(returning: reminders.contains { $0.notes == marker })
            }
        }
    }

    func add(_ delivery: ReminderDelivery, for todo: UUID) throws {
        try requireAccess()
        guard let list = store.calendars(for: .reminder).first(where: {
            $0.calendarIdentifier == delivery.listID && $0.allowsContentModifications
        }) else {
            throw AppFailure.message("这个提醒列表已不可写。请重新选择列表。")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = delivery.title
        reminder.dueDateComponents = delivery.date?.components
        reminder.notes = originMarker(todo)
        try store.save(reminder, commit: true)
    }

    private func requireAccess() throws {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw AppFailure.message("请在「系统设置 → 隐私与安全性 → 提醒事项」允许纸笺访问。")
        }
    }

    private func originMarker(_ todo: UUID) -> String { "来自纸笺 · \(todo.uuidString)" }
}
