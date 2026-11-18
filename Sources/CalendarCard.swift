import SwiftUI

struct CalendarCard: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.paperAccent) private var accent
    let event: PaperEvent
    let number: Int
    let page: Int
    let selected: Bool
    let locate: () -> Void
    private let hasExactTimes: Bool

    @State private var title: String
    @State private var day: Date
    @State private var hasDate: Bool
    @State private var hasTime: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var allDay: Bool
    @State private var error: String?
    @State private var validatingPrevious = false

    init(workspace: Workspace, event: PaperEvent, number: Int, page: Int, selected: Bool, locate: @escaping () -> Void) {
        self.workspace = workspace
        self.event = event
        self.number = number
        self.page = page
        self.selected = selected
        self.locate = locate
        let saved = event.delivery
        let day = saved?.start ?? event.date?.date ?? .now
        let proposedStart = Self.time(event.startTime, on: day)
        let proposedEnd = Self.time(event.endTime, on: day)
        let start = saved?.start ?? proposedStart ?? Self.time("09:00", on: day) ?? day
        hasExactTimes = proposedStart != nil && proposedEnd != nil
        _title = State(initialValue: saved?.title ?? event.title)
        _day = State(initialValue: day)
        _hasDate = State(initialValue: saved != nil || event.date != nil)
        _hasTime = State(initialValue: saved != nil || hasExactTimes)
        _start = State(initialValue: start)
        _end = State(initialValue: saved?.end ?? proposedEnd ?? start.addingTimeInterval(3600))
        _allDay = State(initialValue: saved?.allDay ?? event.allDay)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        VStack(alignment: .leading, spacing: 10) {
            Button(action: locate) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(L("日历 %@ · 第 %@ 页", number, page), systemImage: "calendar")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accent.color)
                    Text(event.delivery?.title ?? event.title)
                        .font(.callout.weight(.medium))
                    if let text = event.whenText, !text.isEmpty {
                        Text(L("原稿时间 · %@", text)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("定位到第 %@ 张纸稿", page))

            if let delivery = event.delivery, delivery.sent {
                Label(L("已加入日历"), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(accent.color)
                Text(delivery.start, format: delivery.allDay ? .dateTime.year().month().day() :
                        .dateTime.year().month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            } else if selected {
                Divider()
                if event.delivery != nil {
                    Text(L("请在日历中核对上次添加结果。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L("我已核对，尚未加入")) { validatingPrevious = true }
                        .disabled(workspace.isAddingEvent)
                } else {
                    editor
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(selected ? accent.color.opacity(0.08) : Color(nsColor: .controlBackgroundColor), in: shape)
        .overlay {
            shape.strokeBorder(selected ? accent.color.opacity(0.58) : PaperTheme.divider).allowsHitTesting(false)
        }
        .confirmationDialog(L("已检查日历，确认没有添加这个日程？"), isPresented: $validatingPrevious) {
            Button(L("允许重新添加")) {
                do { try workspace.resetPendingEvent(event.id); error = nil }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField(L("日程标题"), text: $title).textFieldStyle(.roundedBorder)
                .accessibilityLabel(L("日程标题"))
            if event.date == nil {
                Toggle(L("设置日期"), isOn: $hasDate).toggleStyle(.checkbox)
            }
            if hasDate {
                DatePicker(L("日期"), selection: $day, displayedComponents: .date)
            }
            Toggle(L("全天"), isOn: $allDay).toggleStyle(.checkbox)
            if !allDay {
                if !hasExactTimes {
                    Toggle(L("设置起止时间"), isOn: $hasTime).toggleStyle(.checkbox)
                }
                if hasTime {
                    DatePicker(L("开始"), selection: $start, displayedComponents: .hourAndMinute)
                    DatePicker(L("结束"), selection: $end, displayedComponents: .hourAndMinute)
                    if interval == nil {
                        Text(L("结束时间应晚于开始时间。")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text(L("加入系统默认日历")).font(.caption).foregroundStyle(.secondary)
            Button(L("加入日历"), action: add)
                .buttonStyle(.borderedProminent)
                .disabled(!hasDate || interval == nil ||
                          title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          workspace.isWorking || workspace.isAddingEvent)
        }
    }

    private var interval: DateInterval? {
        guard allDay || hasTime else { return nil }
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: day)
        if allDay, let nextDay = calendar.date(byAdding: .day, value: 1, to: midnight) {
            return DateInterval(start: midnight, end: nextDay)
        }
        let times = [start, end].map { date -> Date? in
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: midnight)
        }
        guard let start = times[0], let end = times[1], end > start,
              calendar.isDate(end, inSameDayAs: midnight) else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func time(_ value: String?, on day: Date) -> Date? {
        guard let value else { return nil }
        let parts = value.split(separator: ":")
        guard parts.map(\.count) == [2, 2], let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    private func add() {
        guard hasDate, let interval else { return }
        let title = title
        let allDay = allDay
        error = nil
        Task {
            do {
                try await workspace.addCalendarEvent(event.id, title: title, start: interval.start,
                                                     end: interval.end, allDay: allDay)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
