import Foundation
import AppKit

struct PaperPage: Identifiable {
    let id: UUID
    let source: ImportedPage
    var preparedPNG: Data?
    var automaticCorners: [PagePoint]?
    var cornerSuggestions: [[PagePoint]] = []
    var appliedCorners: [PagePoint]?
    var trimBounds: MarginBounds?
    var enhanced = false

    let originalImage: NSImage?
    var preparedImage: NSImage?

    init(id: UUID = UUID(), source: ImportedPage, preparedPNG: Data? = nil) {
        self.id = id
        self.source = source
        self.preparedPNG = preparedPNG
        self.originalImage = NSImage(data: source.originalPNG)
        self.preparedImage = preparedPNG.flatMap(NSImage.init(data:))
    }

    var recognitionPNG: Data { preparedPNG ?? source.originalPNG }
    var image: NSImage? { preparedImage ?? originalImage }
}

struct ReviewItem: Codable, Identifiable {
    var id = UUID()
    let category: String
    let location: String
    let detail: String
    var resolved = false
    var anchor: String? = nil
    var box: ReviewBox? = nil
}

struct ReviewBox: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var visibleRect: CGRect? {
        guard [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        let area = CGRect(x: x, y: y, width: width, height: height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return !area.isNull && area.width >= 0.008 && area.height >= 0.008
            && area.width * area.height < 0.65 ? area : nil
    }
}

struct NoteRecord: Codable, Identifiable {
    struct Page: Codable {
        let id: UUID
        let name: String
        let isScan: Bool
        let hasPreparedImage: Bool
        let automaticCorners: [PagePoint]?
        let cornerSuggestions: [[PagePoint]]?
        let appliedCorners: [PagePoint]?
        let trimBounds: MarginBounds?
        let enhanced: Bool
        var markdown: String?
        var issues: [ReviewItem] = []
        var todos: [PaperTodo]?
        var events: [PaperEvent]?
        var error: String?
        var usage: APIUsage?

        init(_ page: PaperPage) {
            id = page.id
            name = page.source.name
            isScan = page.source.isScan
            hasPreparedImage = page.preparedPNG != nil
            automaticCorners = page.automaticCorners
            cornerSuggestions = page.cornerSuggestions.isEmpty ? nil : page.cornerSuggestions
            appliedCorners = page.appliedCorners
            trimBounds = page.trimBounds
            enhanced = page.enhanced
        }
    }

    var id = UUID()
    var created = Date()
    let model: RecognitionModel
    var pages: [Page]
    var editedMarkdown: String?

    var markdown: String {
        editedMarkdown ?? pages.compactMap(\.markdown).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var title: String {
        let first = markdown.split(whereSeparator: \.isNewline)
            .map {
                $0.replacingOccurrences(of: "<u>", with: "").replacingOccurrences(of: "</u>", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#* ").union(.whitespaces))
            }
            .first { !$0.isEmpty && !$0.hasPrefix("`") }
        let fallback = pages.first?.name ?? L("纸稿")
        return String((first ?? fallback).prefix(52))
    }

    var completedCount: Int { pages.filter { $0.markdown != nil }.count }
    var usage: APIUsage? {
        let usages = pages.compactMap(\.usage)
        let input = usages.compactMap(\.inputTokens)
        let output = usages.compactMap(\.outputTokens)
        guard !input.isEmpty, !output.isEmpty else { return nil }
        return APIUsage(inputTokens: input.reduce(0, +), outputTokens: output.reduce(0, +))
    }
}

struct NoteLibrary {
    let root: URL
    private let files = FileManager.default

    static var local: Self {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(root: base.appendingPathComponent("PaperNotes/History", isDirectory: true))
    }

    func list() throws -> [NoteRecord] {
        guard files.fileExists(atPath: root.path) else { return [] }
        return try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map { try readManifest($0) }
            .sorted { $0.created > $1.created }
    }

    func create(_ record: NoteRecord, from pages: [PaperPage]) throws {
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent("." + record.id.uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        for page in pages {
            try page.source.originalPNG.write(to: image(staging, page.id, prepared: false), options: .atomic)
            if let png = page.preparedPNG {
                try png.write(to: image(staging, page.id, prepared: true), options: .atomic)
            }
        }
        try writeManifest(record, at: staging)
        try files.moveItem(at: staging, to: directory(record.id))
    }

    func save(_ record: NoteRecord) throws { try writeManifest(record, at: directory(record.id)) }

    func reopen(_ record: NoteRecord) throws -> [PaperPage] {
        try record.pages.map { try reopenPage($0, in: record.id) }
    }

    func reopenPage(_ page: NoteRecord.Page, in recordID: UUID) throws -> PaperPage {
        let folder = directory(recordID)
        let original = try Data(contentsOf: image(folder, page.id, prepared: false))
        let prepared = page.hasPreparedImage ? try Data(contentsOf: image(folder, page.id, prepared: true)) : nil
        let source = ImportedPage(originalPNG: original, name: page.name, isScan: page.isScan)
        var item = PaperPage(id: page.id, source: source, preparedPNG: prepared)
        item.automaticCorners = page.automaticCorners
        item.cornerSuggestions = page.cornerSuggestions ?? []
        item.appliedCorners = page.appliedCorners
        item.trimBounds = page.trimBounds
        item.enhanced = page.enhanced
        return item
    }

    func trash(_ id: UUID) throws { try files.trashItem(at: directory(id), resultingItemURL: nil) }

    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func image(_ folder: URL, _ id: UUID, prepared: Bool) -> URL {
        folder.appendingPathComponent(id.uuidString + (prepared ? "-prepared.png" : "-source.png"))
    }

    private func readManifest(_ folder: URL) throws -> NoteRecord {
        try JSONDecoder().decode(NoteRecord.self, from: Data(contentsOf: folder.appendingPathComponent("note.json")))
    }

    private func writeManifest(_ record: NoteRecord, at folder: URL) throws {
        try JSONEncoder().encode(record).write(to: folder.appendingPathComponent("note.json"), options: .atomic)
    }
}
