import SwiftUI

struct ReminderCard: View {
    @ObservedObject var workspace: Workspace
    let todo: PaperTodo
    let number: Int
    let page: Int
    let selected: Bool
    let locate: () -> Void

    @State private var title: String
    @State private var date: Date
    @State private var hasDate: Bool
    @State private var listID: String?
    @State private var loading = false
    @State private var error: String?

    init(workspace: Workspace, todo: PaperTodo, number: Int, page: Int, selected: Bool, locate: @escaping () -> Void) {
        self.workspace = workspace
        self.todo = todo
        self.number = number
        self.page = page
        self.selected = selected
        self.locate = locate
        let proposed = todo.delivery == nil ? todo.date : todo.delivery?.date
        _title = State(initialValue: todo.delivery?.title ?? todo.title)
        _date = State(initialValue: proposed?.date ?? .now)
        _hasDate = State(initialValue: proposed != nil)
        _listID = State(initialValue: todo.delivery?.listID)
    }

    private var lists: [ReminderList] { workspace.availableReminderLists ?? [] }

    private var selectedList: ReminderList? {
        if let listID { return lists.first { $0.id == listID } }
        return lists.first(where: \.isDefault) ?? lists.first
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        VStack(alignment: .leading, spacing: 10) {
            Button(action: locate) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("待办 \(number) · 第 \(page) 页", systemImage: "checklist")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PaperTheme.accent)
                    Text(todo.delivery?.title ?? todo.title)
                        .font(.callout.weight(.medium))
                    if let dueText = todo.dueText, !dueText.isEmpty {
                        Text("原稿日期 · \(dueText)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("定位到第 \(page) 张纸稿")

            if let delivery = todo.delivery, delivery.sent {
                Label("已加入 · \(delivery.listLabel)", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(PaperTheme.accent)
                    .accessibilityLabel("已加入提醒事项 · \(delivery.listLabel)")
                if let deadline = delivery.date?.date {
                    Text(deadline, format: .dateTime.year().month().day())
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if selected {
                Divider()
                editor
            }
        }
        .padding(10)
        .background(selected ? PaperTheme.accent.opacity(0.08) : Color(nsColor: .controlBackgroundColor), in: shape)
        .overlay {
            shape.strokeBorder(selected ? PaperTheme.accent.opacity(0.58) : PaperTheme.divider)
                .allowsHitTesting(false)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("标题").font(.caption).foregroundStyle(.secondary)
                TextField("待办标题", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("待办标题")
            }
            Toggle("设置截止日期", isOn: $hasDate)
                .toggleStyle(.checkbox)
            if hasDate {
                DatePicker("截止日期", selection: $date, displayedComponents: .date)
                    .labelsHidden()
            }
            if !lists.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("提醒列表").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Picker("提醒列表", selection: Binding(get: { selectedList?.id ?? "" },
                                                             set: { listID = $0 })) {
                            if selectedList == nil { Text("选择列表").tag("") }
                            ForEach(lists) { Text($0.label).tag($0.id) }
                        }
                        .labelsHidden()
                        .help(selectedList?.label ?? "选择提醒列表")
                        Button(action: loadLists) { Image(systemName: "arrow.clockwise") }
                            .help("刷新提醒列表")
                            .accessibilityLabel("刷新提醒列表")
                            .disabled(loading)
                    }
                }
                Button("加入提醒事项", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedList == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              workspace.isWorking || workspace.isAddingReminder || loading)
            } else {
                Button("选择提醒列表…", action: loadLists)
                    .disabled(loading)
            }
            if loading {
                ProgressView().controlSize(.small).accessibilityLabel("正在读取提醒列表")
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func loadLists() {
        loading = true
        error = nil
        Task {
            defer { loading = false }
            do {
                try await workspace.loadReminderLists()
                if lists.isEmpty { error = "请在提醒事项中创建一个可用列表，再回来重试。" }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func add() {
        guard let list = selectedList else { return }
        let title = title
        let deadline = hasDate ? ReminderDay(date) : nil
        error = nil
        Task {
            do { try await workspace.addReminder(todo.id, to: list, title: title, date: deadline) }
            catch { self.error = error.localizedDescription }
        }
    }
}
