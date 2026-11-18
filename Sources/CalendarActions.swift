import EventKit
import Foundation

struct PaperEvent: Codable, Identifiable {
    var id = UUID()
    let title: String
    let whenText: String?
    let date: ReminderDay?
    let startTime: String?
    let endTime: String?
    let allDay: Bool
    let anchor: String?
    let box: ReviewBox?
    var delivery: CalendarDelivery?
}

struct CalendarDelivery: Codable {
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    var sent = false
}

@MainActor
protocol CalendarService {
    func authorize() async throws
    func add(_ delivery: CalendarDelivery) throws
}

@MainActor
final class AppleCalendar: CalendarService {
    private lazy var store = EKEventStore()

    func authorize() async throws {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            _ = try await store.requestWriteOnlyAccessToEvents()
            store.reset()
        }
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .writeOnly || status == .fullAccess else {
            throw AppFailure.message(L("请在「系统设置 → 隐私与安全性 → 日历」允许纸笺添加日程。"))
        }
    }

    func add(_ delivery: CalendarDelivery) throws {
        guard let target = store.defaultCalendarForNewEvents else {
            throw AppFailure.message(L("请先在日历设置中选择一个默认日历。"))
        }
        let event = EKEvent(eventStore: store)
        event.calendar = target
        event.title = delivery.title
        event.startDate = delivery.start
        event.endDate = delivery.end
        event.isAllDay = delivery.allDay
        try store.save(event, span: .thisEvent, commit: true)
    }
}
