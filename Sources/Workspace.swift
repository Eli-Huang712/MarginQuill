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
    @Published private(set) var hasKey: Bool
    @Published private(set) var imagesChanged = false
    @Published var selectedPageID: UUID?
    @Published var model = RecognitionModel.terra
    @Published var showingSource = false
    @Published var showingHistory = UserDefaults.standard.bool(forKey: "showsHistorySidebar") {
        didSet { UserDefaults.standard.set(showingHistory, forKey: "showsHistorySidebar") }
    }
    @Published var notice = ""
    @Published var error: String?
    @Published var showingSettings = false

    private let library: NoteLibrary
    private let client: RecognitionClient
    private let loadKey: () -> String?
    private var recognition: Task<Void, Never>?
    private var requestID: UUID?

    init(library: NoteLibrary = .local, client: RecognitionClient = RecognitionClient(),
         loadKey: @escaping () -> String? = Keychain.load) {
        self.library = library
        self.client = client
        self.loadKey = loadKey
        hasKey = loadKey() != nil
        do { history = try library.list() }
        catch { self.error = "部分历史记录无法载入。\(error.localizedDescription)" }
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
        panel.prompt = "导入"
        guard panel.runModal() == .OK else { return }
        load(urls: panel.urls)
    }

    func load(urls: [URL]) {
        guard !isWorking else { return }
        var imported: [ImportedPage] = []
        var failures: [String] = []
        for url in urls {
            do {
                imported += try ImportedPage.decode(Data(contentsOf: url), name: url.lastPathComponent)
            } catch {
                failures.append(url.lastPathComponent)
            }
        }
        append(imported)
        if !failures.isEmpty {
            error = "这些文件无法导入：\(failures.joined(separator: "、"))"
        }
    }

    @discardableResult
    func load(data: Data, name: String) -> Bool {
        guard !isWorking else { return false }
        do {
            append(try ImportedPage.decode(data, name: name))
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func append(_ imports: [ImportedPage]) {
        guard !imports.isEmpty else { return }
        let newPages = imports.map { PaperPage(source: $0) }
        pages += newPages
        selectedPageID = newPages.first?.id
        imagesChanged = true
        let jobs = newPages.map { ($0.id, $0.source) }
        isPreparing = true
        error = nil
        Task {
            defer { isPreparing = false }
            var failed = 0
            for (index, job) in jobs.enumerated() {
                notice = "正在预处理 \(index + 1)/\(jobs.count) 页…"
                do {
                    let output = try await Task.detached(priority: .userInitiated) {
                        try await PhotoPreprocessor.run(job.1)
                    }.value
                    updatePage(id: job.0, output: output, crop: .automatic, enhanced: false)
                } catch {
                    failed += 1
                    self.error = error.localizedDescription
                }
            }
            notice = failed == 0 ? "已导入 \(newPages.count) 页" : "\(failed) 页使用原图"
        }
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

    func processPage(_ id: UUID, crop: PhotoPreprocessor.Crop, enhance: Bool) async -> Bool {
        guard !isWorking, let page = pages.first(where: { $0.id == id }) else { return false }
        isPreparing = true
        defer { isPreparing = false }
        error = nil
        notice = "正在裁正纸稿…"
        do {
            let output = try await Task.detached(priority: .userInitiated) {
                try await PhotoPreprocessor.run(page.source, crop: crop, enhance: enhance)
            }.value
            updatePage(id: id, output: output, crop: crop, enhanced: enhance)
            imagesChanged = true
            notice = output.corners == nil ? "使用完整纸页" : "已应用角点"
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
        pages[index].enhanced = enhanced
        if output.corners == nil, !enhanced {
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
        notice = "正在查找纸边…"
        error = nil
        defer { isPreparing = false }
        do {
            let source = ImportedPage(originalPNG: page.source.originalPNG, name: page.source.name, isScan: false)
            let detection = try await Task.detached(priority: .userInitiated) {
                try await PhotoPreprocessor.run(source)
            }.value
            guard let index = pages.firstIndex(where: { $0.id == id }) else { return false }
            pages[index].automaticCorners = detection.corners
            pages[index].cornerSuggestions = detection.suggestions
            notice = detection.suggestions.isEmpty ? "可手动调整纸页四角" : "已找到 \(detection.suggestions.count) 个纸边候选"
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func recognize() {
        guard !isWorking, !pages.isEmpty else { return }
        guard let key = loadKey(), !key.isEmpty else {
            showingSettings = true
            return
        }
        guard let url = Bundle.main.url(forResource: "transcription_prompt", withExtension: "txt"),
              let prompt = try? String(contentsOf: url, encoding: .utf8) else {
            error = "找不到识别提示词。"
            return
        }

        var target: NoteRecord
        if canResume, let current = record, current.model == model {
            target = current
        } else {
            target = NoteRecord(model: model, pages: pages.map(NoteRecord.Page.init))
            do { try library.create(target, from: pages) }
            catch {
                self.error = "无法建立历史记录。\(error.localizedDescription)"
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
        isRecognizing = true
        imagesChanged = false
        showingSource = false
        error = nil

        recognition = Task {
            defer {
                if requestID == id {
                    recognition = nil
                    requestID = nil
                    isRecognizing = false
                }
            }
            for (index, png) in pending {
                notice = "正在识别第 \(index + 1)/\(target.pages.count) 页…"
                do {
                    let result = try await client.recognize(png: png, model: target.model, key: key, prompt: prompt)
                    guard !Task.isCancelled, requestID == id else { return }
                    target.pages[index].markdown = result.markdown
                    target.pages[index].issues = result.issues
                    target.pages[index].usage = result.usage
                    target.pages[index].error = nil
                } catch {
                    guard !Task.isCancelled, requestID == id else { return }
                    target.pages[index].error = error.localizedDescription
                    if !persist(target) { return }
                    notice = "第 \(index + 1) 页暂停 · 已完成 \(target.completedCount)/\(target.pages.count) 页"
                    return
                }
                if !persist(target) { return }
            }
            notice = "已按顺序整理 \(target.completedCount) 页"
        }
    }

    func cancelRecognition() {
        recognition?.cancel()
        recognition = nil
        requestID = nil
        isRecognizing = false
        notice = "已停止等待，已完成的页面已保存"
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
            self.error = "历史记录暂未写入。\(error.localizedDescription)"
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
            notice = "已打开历史记录"
            error = nil
        } catch {
            self.error = "无法打开历史记录。\(error.localizedDescription)"
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
           saved.appliedCorners == page.appliedCorners, saved.enhanced == page.enhanced {
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
            notice = "记录已移到废纸篓"
            error = nil
        } catch {
            self.error = "无法将记录移到废纸篓。\(error.localizedDescription)"
        }
    }

    func newNote() {
        guard !isWorking else { return }
        do { try saveCurrentDraft() }
        catch {
            self.error = "无法保存当前纸稿。\(error.localizedDescription)"
            return
        }
        pages = []
        record = nil
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
            self.error = "无法保存当前纸稿。\(error.localizedDescription)"
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
            notice = "已复制 Markdown"
            error = nil
        }
    }

    func export() {
        guard !markdown.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "纸稿笔记.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            notice = "已导出 \(url.lastPathComponent)"
            error = nil
        } catch {
            self.error = "无法导出 Markdown。\(error.localizedDescription)"
        }
    }

    func storeKey(_ raw: String) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AppFailure.message("请输入 API 密钥。") }
        try Keychain.save(key)
        hasKey = true
    }

    func deleteKey() throws {
        try Keychain.remove()
        hasKey = false
    }
}
