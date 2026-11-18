import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class Workspace: ObservableObject {
    @Published private(set) var pages: [PaperPage] = []
    @Published private(set) var record: NoteRecord?
    @Published private(set) var history: [NoteRecord] = []
    @Published private(set) var isPreparing = false
    @Published private(set) var isRecognizing = false
    @Published private(set) var recognitionProgress: (completed: Int, total: Int)?
    @Published private(set) var streamedPage: PreviewSection?
    @Published private(set) var isAddingReminder = false
    @Published private(set) var isAddingEvent = false
    @Published private(set) var availableReminderLists: [ReminderList]?
    @Published private(set) var hasKey: Bool
    @Published private(set) var imagesChanged = false
    @Published var selectedPageID: UUID?
    @Published var model = RecognitionModel.preferred
    @Published var showingSource = false
    @Published var showingHistory = UserDefaults.standard.bool(forKey: "showsHistorySidebar") {
        didSet { UserDefaults.standard.set(showingHistory, forKey: "showsHistorySidebar") }
    }
    @Published var notice = ""
    @Published var error: String?
    @Published var showingSettings = false
    @Published var settingsSection = SettingsSection.general

    private let library: NoteLibrary
    private let client: RecognitionClient
    private let reminders: any ReminderService
    private let calendar: any CalendarService
    private let keyFile: APIKeyFile
    private let loadKey: () -> String?
    private var recognition: Task<Void, Never>?
    private var requestID: UUID?

    init(library: NoteLibrary = .local, client: RecognitionClient = RecognitionClient(),
         loadKey: (() -> String?)? = nil, reminders: (any ReminderService)? = nil,
         calendar: (any CalendarService)? = nil, keyFile: APIKeyFile = .local) {
        self.library = library
        self.client = client
        self.reminders = reminders ?? AppleReminders()
        self.calendar = calendar ?? AppleCalendar()
        self.keyFile = keyFile
        let keyLoader = loadKey ?? keyFile.load
        self.loadKey = keyLoader
        hasKey = keyLoader() != nil
        do { history = try library.list() }
        catch { self.error = L("部分历史记录无法载入。%@", error.localizedDescription) }
    }

    var selectedPage: PaperPage? { pages.first { $0.id == selectedPageID } }
    var selectedIndex: Int? { pages.firstIndex { $0.id == selectedPageID } }
    var markdown: String { record?.markdown ?? "" }
    var isWorking: Bool { isPreparing || isRecognizing }
    var canResume: Bool {
        guard let record, !imagesChanged, record.editedMarkdown == nil else { return false }
        return record.completedCount < record.pages.count && !record.pages.isEmpty
    }

    func chooseFile() {
        guard !isWorking else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = L("导入")
        guard panel.runModal() == .OK else { return }
        load(urls: panel.urls)
    }

    func load(urls: [URL]) {
        guard !urls.isEmpty else { return }
        importPages {
            var imported: [ImportedPage] = []
            var failures: [String] = []
            for url in urls {
                do {
                    imported += try ImportedPage.decode(Data(contentsOf: url), name: url.lastPathComponent)
                } catch {
                    failures.append(url.lastPathComponent)
                }
            }
            let error = failures.isEmpty ? nil : L("这些文件无法导入：%@", failures.joined(separator: L("、")))
            return (imported, error)
        }
    }

    @discardableResult
    func load(captures: [(data: Data, name: String)]) -> Bool {
        guard !captures.isEmpty else { return false }
        return importPages {
            var imported: [ImportedPage] = []
            var firstError: String?
            for capture in captures {
                do {
                    imported += try ImportedPage.decode(capture.data, name: capture.name)
                } catch {
                    firstError = firstError ?? error.localizedDescription
                }
            }
            return (imported, firstError)
        }
    }

    @discardableResult
    private func importPages(_ read: @escaping @Sendable () -> (pages: [ImportedPage], error: String?)) -> Bool {
        guard !isWorking else { return false }
        isPreparing = true
        error = nil
        notice = L("正在读取纸稿…")
        let start = ContinuousClock.now
        Task {
            defer { isPreparing = false }
            let (imports, importError) = await Task.detached(priority: .userInitiated, operation: read).value
            error = importError
            guard !imports.isEmpty else {
                notice = ""
                return
            }
            let newPages = imports.map { PaperPage(source: $0) }
            pages += newPages
            selectedPageID = newPages.first?.id
            imagesChanged = true
            notice = L("正在预处理 %@ 页…", newPages.count)
            do {
                let results = try await Task.detached(priority: .userInitiated) {
                    try await PhotoPreprocessor.runBatch(imports)
                }.value
                var failed = 0
                for (page, result) in zip(newPages, results) {
                    switch result {
                    case .success(let output):
                        updatePage(id: page.id, output: output, crop: .automatic, enhanced: false)
                    case .failure(let error):
                        failed += 1
                        self.error = error.localizedDescription
                    }
                }
                let elapsed = start.duration(to: .now).formatted(.units(allowed: [.seconds], width: .abbreviated,
                                                                         fractionalPart: .show(length: 1)))
                notice = failed == 0 ? L("已导入 %@ 页 · %@", newPages.count, elapsed) : L("%@ 页使用原图", failed)
            } catch {
                notice = L("%@ 页使用原图", newPages.count)
                self.error = error.localizedDescription
            }
        }
        return true
    }

    func movePage(_ id: UUID, by offset: Int) {
        guard let index = pages.firstIndex(where: { $0.id == id }),
              pages.indices.contains(index + offset) else { return }
        movePage(id, to: pages[index + offset].id)
    }

    func movePage(_ source: UUID, to destination: UUID) {
        guard !isWorking, source != destination,
              let from = pages.firstIndex(where: { $0.id == source }),
              let to = pages.firstIndex(where: { $0.id == destination }) else { return }
        let moving = pages.remove(at: from)
        pages.insert(moving, at: to)
        imagesChanged = true
    }

    func removePage(_ id: UUID) {
        guard !isWorking, let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages.remove(at: index)
        if selectedPageID == id {
            selectedPageID = pages.isEmpty ? nil : pages[min(index, pages.count - 1)].id
        }
        imagesChanged = true
    }

    func processPage(_ id: UUID, crop: PhotoPreprocessor.Crop, enhance: Bool, trim: Bool = true) async -> Bool {
        guard !isWorking, let page = pages.first(where: { $0.id == id }) else { return false }
        isPreparing = true
        defer { isPreparing = false }
        error = nil
        notice = L("正在裁正纸稿…")
        do {
            let output = try await Task.detached(priority: .userInitiated) {
                try await PhotoPreprocessor.run(page.source, crop: crop, enhance: enhance, trim: trim)
            }.value
            updatePage(id: id, output: output, crop: crop, enhanced: enhance)
            imagesChanged = true
            if output.trimBounds != nil {
                notice = L("已裁外围留白")
            } else {
                notice = output.corners == nil ? L("使用完整纸页") : L("已应用角点")
            }
            return true
        } catch {
            notice = ""
            self.error = error.localizedDescription
            return false
        }
    }

    private func updatePage(id: UUID, output: PhotoPreprocessor.Output, crop: PhotoPreprocessor.Crop, enhanced: Bool) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        if case .automatic = crop {
            pages[index].automaticCorners = output.corners
            pages[index].cornerSuggestions = output.suggestions
        }
        pages[index].appliedCorners = output.corners
        pages[index].trimBounds = output.trimBounds
        pages[index].enhanced = enhanced
        if output.corners == nil, output.trimBounds == nil, !enhanced {
            pages[index].preparedPNG = nil
            pages[index].preparedImage = nil
        } else {
            pages[index].preparedPNG = output.png
            pages[index].preparedImage = NSImage(data: output.png)
        }
    }

    func detectCorners(for id: UUID) async -> Bool {
        guard !isWorking, let page = pages.first(where: { $0.id == id }) else { return false }
        isPreparing = true
        notice = L("正在查找纸边…")
        error = nil
        defer { isPreparing = false }
        do {
            let source = ImportedPage(originalPNG: page.source.originalPNG, name: page.source.name, isScan: false)
            let detection = try await Task.detached(priority: .userInitiated) {
                try await PhotoPreprocessor.run(source, trim: false, detectOnly: true)
            }.value
            guard let index = pages.firstIndex(where: { $0.id == id }) else { return false }
            pages[index].automaticCorners = detection.corners
            pages[index].cornerSuggestions = detection.suggestions
            notice = detection.suggestions.isEmpty ? L("可手动调整纸页四角") : L("已找到 %@ 个纸边候选", detection.suggestions.count)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func recognize() {
        guard !isWorking, !pages.isEmpty else { return }
        let savedKey = loadKey()
        hasKey = savedKey != nil
        guard let key = savedKey, !key.isEmpty else {
            settingsSection = .recognition
            showingSettings = true
            return
        }
        guard let url = Bundle.main.url(forResource: "transcription_prompt", withExtension: "txt"),
              let prompt = try? String(contentsOf: url, encoding: .utf8) else {
            error = L("找不到识别提示词。")
            return
        }

        var target: NoteRecord
        if canResume, let current = record, current.model == model {
            target = current
        } else {
            target = NoteRecord(model: model, pages: pages.map(NoteRecord.Page.init))
            do { try library.create(target, from: pages) }
            catch {
                self.error = L("无法建立历史记录。%@", error.localizedDescription)
                return
            }
            updateRecord(target)
        }

        let pending = target.pages.enumerated().compactMap { index, entry -> (Int, Data)? in
            guard entry.markdown == nil, let page = pages.first(where: { $0.id == entry.id }) else { return nil }
            return (index, page.recognitionPNG)
        }
        guard !pending.isEmpty else { return }
        let id = UUID()
        requestID = id
        recognitionProgress = (target.completedCount, target.pages.count)
        isRecognizing = true
        imagesChanged = false
        showingSource = false
        error = nil

        recognition = Task {
            defer {
                if requestID == id {
                    recognition = nil
                    requestID = nil
                    recognitionProgress = nil
                    streamedPage = nil
                    isRecognizing = false
                }
            }
            let total = target.pages.count
            for (index, png) in pending {
                let pageID = target.pages[index].id.uuidString
                let pageNumber = index + 1
                notice = L("正在提交第 %@/%@ 页…", pageNumber, total)
                do {
                    let result = try await client.recognize(png: png, model: target.model, key: key, prompt: prompt) { update in
                        guard self.requestID == id else { return }
                        switch update {
                        case .waitingForModel:
                            self.notice = L("等待识别第 %@/%@ 页…", pageNumber, total)
                        case .markdown(let markdown):
                            if self.streamedPage == nil {
                                self.notice = L("正在输出第 %@/%@ 页…", pageNumber, total)
                            }
                            self.streamedPage = PreviewSection(id: pageID, markdown: markdown)
                        }
                    }
                    guard !Task.isCancelled, requestID == id else { return }
                    notice = L("正在保存第 %@/%@ 页…", pageNumber, total)
                    target.pages[index].markdown = result.markdown
                    target.pages[index].issues = result.issues
                    target.pages[index].todos = result.todos
                    target.pages[index].events = result.events
                    target.pages[index].usage = result.usage
                    target.pages[index].error = nil
                } catch {
                    guard !Task.isCancelled, requestID == id else { return }
                    target.pages[index].error = error.localizedDescription
                    if !persist(target) { return }
                    notice = L("第 %@ 页暂停 · 已完成 %@/%@ 页", pageNumber, target.completedCount, total)
                    return
                }
                if !persist(target) { return }
                streamedPage = nil
                recognitionProgress = (target.completedCount, total)
            }
            notice = L("已按顺序整理 %@ 页", target.completedCount)
        }
    }

    func cancelRecognition() {
        recognition?.cancel()
        recognition = nil
        requestID = nil
        recognitionProgress = nil
        streamedPage = nil
        isRecognizing = false
        notice = L("已停止等待，已完成的页面已保存")
    }

    private func updateRecord(_ updated: NoteRecord) {
        record = updated
        if let index = history.firstIndex(where: { $0.id == updated.id }) {
            history[index] = updated
        } else {
            history.insert(updated, at: 0)
        }
    }

    @discardableResult
    private func persist(_ updated: NoteRecord) -> Bool {
        updateRecord(updated)
        do { try library.save(updated) }
        catch {
            self.error = L("历史记录暂未写入。%@", error.localizedDescription)
            return false
        }
        return true
    }

    func editMarkdown(_ value: String) {
        guard !isRecognizing, var record, record.markdown != value else { return }
        record.editedMarkdown = value
        persist(record)
    }

    func markIssue(_ issue: UUID, page: UUID, resolved: Bool) {
        guard !isRecognizing, var record,
              let index = record.pages.firstIndex(where: { $0.id == page }),
              let item = record.pages[index].issues.firstIndex(where: { $0.id == issue }) else { return }
        record.pages[index].issues[item].resolved = resolved
        persist(record)
    }

    func loadReminderLists() async throws { availableReminderLists = try await reminders.lists() }

    func addReminder(_ id: UUID, to list: ReminderList, title: String, date: ReminderDay?) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw AppFailure.message(L("请输入待办标题。")) }
        guard !isWorking, !isAddingReminder, let current = record,
              let todo = current.pages.lazy.compactMap({ $0.todos?.first { $0.id == id } }).first else {
            throw AppFailure.message(L("纸稿正在处理或已切换，请稍后再试。"))
        }
        if todo.delivery?.sent == true { return }
        isAddingReminder = true
        defer { isAddingReminder = false }

        // A previously reserved delivery may have reached Reminders before the manifest was updated.
        if var prior = todo.delivery, try await reminders.contains(id, in: prior.listID) {
            prior.sent = true
            let updated = try recordingDelivery(prior, for: id, recordID: current.id)
            persist(updated)
            return
        }
        try Task.checkCancellation()
        var delivery = ReminderDelivery(title: title, date: date, listID: list.id, listLabel: list.label)
        var updated = try recordingDelivery(delivery, for: id, recordID: current.id)
        try library.save(updated)
        updateRecord(updated)

        try reminders.add(delivery, for: id)
        delivery.sent = true
        updated = try recordingDelivery(delivery, for: id, recordID: current.id)
        error = nil
        notice = L("已加入提醒事项")
        persist(updated)
    }

    private func recordingDelivery(_ delivery: ReminderDelivery, for id: UUID, recordID: UUID) throws -> NoteRecord {
        guard !isWorking, var record, record.id == recordID,
              let page = record.pages.firstIndex(where: { $0.todos?.contains { $0.id == id } == true }),
              let index = record.pages[page].todos?.firstIndex(where: { $0.id == id }) else {
            throw AppFailure.message(L("纸稿已切换，请重新打开该待办。"))
        }
        record.pages[page].todos?[index].delivery = delivery
        return record
    }

    func addCalendarEvent(_ id: UUID, title: String, start: Date, end: Date, allDay: Bool) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, end > start else {
            throw AppFailure.message(L("请输入标题，并确认结束时间晚于开始时间。"))
        }
        guard !isWorking, !isAddingEvent, let current = record,
              let event = current.pages.lazy.compactMap({ $0.events?.first { $0.id == id } }).first,
              event.delivery == nil else { return }
        isAddingEvent = true
        defer { isAddingEvent = false }

        try await calendar.authorize()
        try Task.checkCancellation()
        // Reserve before writing. An interrupted write must be checked in Calendar before retrying.
        var delivery = CalendarDelivery(title: title, start: start, end: end, allDay: allDay)
        var updated = try recordingEvent(delivery, for: id, recordID: current.id)
        try library.save(updated)
        updateRecord(updated)
        try calendar.add(delivery)
        delivery.sent = true
        updated = try recordingEvent(delivery, for: id, recordID: current.id)
        error = nil
        notice = L("已加入日历")
        persist(updated)
    }

    func resetPendingEvent(_ id: UUID) throws {
        guard !isAddingEvent, let current = record,
              current.pages.contains(where: { $0.events?.contains { $0.id == id && $0.delivery?.sent == false } == true }) else {
            return
        }
        let updated = try recordingEvent(nil, for: id, recordID: current.id)
        try library.save(updated)
        updateRecord(updated)
    }

    private func recordingEvent(_ delivery: CalendarDelivery?, for id: UUID, recordID: UUID) throws -> NoteRecord {
        guard !isWorking, var record, record.id == recordID,
              let page = record.pages.firstIndex(where: { $0.events?.contains { $0.id == id } == true }),
              let index = record.pages[page].events?.firstIndex(where: { $0.id == id }) else {
            throw AppFailure.message(L("纸稿已切换，请重新打开该日程。"))
        }
        record.pages[page].events?[index].delivery = delivery
        return record
    }

    func openHistory(_ id: UUID) {
        guard !isWorking, let snapshot = history.first(where: { $0.id == id }) else { return }
        do {
            let restored = try library.reopen(snapshot)
            try saveCurrentDraft()
            pages = restored
            record = snapshot
            model = snapshot.model
            selectedPageID = restored.first?.id
            showingSource = false
            imagesChanged = false
            notice = L("已打开历史记录")
            error = nil
        } catch {
            self.error = L("无法打开历史记录。%@", error.localizedDescription)
        }
    }

    func showIssuePage(_ id: UUID) {
        if let record, !pages.contains(where: { $0.id == id }) { openHistory(record.id) }
        selectedPageID = id
    }

    func recognizedImage(for id: UUID) -> NSImage? {
        guard let record, let saved = record.pages.first(where: { $0.id == id }) else { return nil }
        if let page = pages.first(where: { $0.id == id }),
           saved.hasPreparedImage == (page.preparedPNG != nil),
           saved.appliedCorners == page.appliedCorners, saved.trimBounds == page.trimBounds,
           saved.enhanced == page.enhanced {
            return page.image
        }
        return (try? library.reopenPage(saved, in: record.id))?.image
    }

    func trashHistory(_ id: UUID) {
        guard !isWorking else { return }
        do {
            try library.trash(id)
            history.removeAll { $0.id == id }
            if record?.id == id {
                pages = []
                record = nil
                selectedPageID = nil
                imagesChanged = false
                showingSource = false
            }
            notice = L("记录已移到废纸篓")
            error = nil
        } catch {
            self.error = L("无法将记录移到废纸篓。%@", error.localizedDescription)
        }
    }

    func newNote() {
        guard !isWorking else { return }
        do { try saveCurrentDraft() }
        catch {
            self.error = L("无法保存当前纸稿。%@", error.localizedDescription)
            return
        }
        pages = []
        record = nil
        model = .preferred
        selectedPageID = nil
        showingSource = false
        imagesChanged = false
        notice = ""
        error = nil
    }

    func finishSession() -> Bool {
        do {
            try saveCurrentDraft()
            return true
        } catch {
            self.error = L("无法保存当前纸稿。%@", error.localizedDescription)
            return false
        }
    }

    private func saveCurrentDraft() throws {
        guard imagesChanged, !pages.isEmpty else { return }
        let draft = NoteRecord(model: model, pages: pages.map(NoteRecord.Page.init))
        try library.create(draft, from: pages)
        history.insert(draft, at: 0)
    }

    func copy() {
        guard !markdown.isEmpty else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(markdown, forType: .string) {
            notice = L("已复制 Markdown")
            error = nil
        }
    }

    func export() {
        guard !markdown.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = L("纸稿笔记.md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            notice = L("已导出 %@", url.lastPathComponent)
            error = nil
        } catch {
            self.error = L("无法导出 Markdown。%@", error.localizedDescription)
        }
    }

    func storeKey(_ raw: String) throws {
        try keyFile.save(raw)
        hasKey = true
    }

    func deleteKey() throws {
        try keyFile.remove()
        hasKey = false
    }

    func migrateKeyFromKeychain() throws {
        try storeKey(LegacyAPIKey.readForMigration())
    }
}
