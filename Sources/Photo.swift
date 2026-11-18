import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct PagePoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    static let fullPage = [
        Self(x: 0, y: 0), Self(x: 1, y: 0), Self(x: 1, y: 1), Self(x: 0, y: 1)
    ]
}

struct MarginBounds: Codable, Equatable, Sendable {
    let left: Int
    let top: Int
    let right: Int
    let bottom: Int
}

struct ImportedPage: Sendable {
    let originalPNG: Data
    let name: String
    let isScan: Bool

    static func decode(_ data: Data, name: String) throws -> [ImportedPage] {
        guard data.starts(with: Data("%PDF".utf8)) else {
            return [Self(originalPNG: try normalize(data), name: name, isScan: false)]
        }
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw AppFailure.message(L("无法读取这份扫描件。"))
        }
        return try (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else {
                throw AppFailure.message(L("无法读取扫描件的第 %@ 页。", index + 1))
            }
            let bounds = page.bounds(for: .cropBox)
            guard min(bounds.width, bounds.height) > 0 else {
                throw AppFailure.message(L("扫描件的页面尺寸无效。"))
            }
            let scale = 2600 / max(bounds.width, bounds.height)
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let preview = page.thumbnail(of: size, for: .cropBox)
            guard let raster = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw AppFailure.message(L("无法生成扫描件预览。"))
            }
            let label = document.pageCount == 1 ? name : "\(name) · \(index + 1)"
            return Self(originalPNG: try encodePNG(raster), name: label, isScan: true)
        }
    }

    private static func normalize(_ data: Data) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4200
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let photo = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AppFailure.message(L("无法读取图片。请选择照片或 PDF。"))
        }
        return try encodePNG(photo)
    }

    static func encodePNG(_ photo: CGImage) throws -> Data {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else {
            throw AppFailure.message(L("无法生成 PNG。"))
        }
        CGImageDestinationAddImage(destination, photo, nil)
        guard CGImageDestinationFinalize(destination) else { throw AppFailure.message(L("无法生成 PNG。")) }
        return buffer as Data
    }
}

enum PhotoPreprocessor {
    enum Crop: Sendable {
        case automatic
        case entirePage
        case manual([PagePoint])
    }

    struct Output: Sendable {
        let png: Data
        let corners: [PagePoint]?
        var suggestions: [[PagePoint]] = []
        var trimBounds: MarginBounds?
    }

    private struct Report: Decodable {
        let corners: [[Double]]?
        let suggestions: [[[Double]]]?
        let trimBounds: MarginBounds?
        let error: String?
    }

    private struct Job: Encodable {
        let source: String
        let output: String
        let straighten: Bool
        let enhance: Bool
        let trim: Bool
        let detectOnly: Bool
        let corners: [[Double]]?
    }

    static func run(_ page: ImportedPage, crop: Crop = .automatic, enhance: Bool = false,
                    trim: Bool = true, detectOnly: Bool = false) async throws -> Output {
        if case .entirePage = crop, !enhance {
            return Output(png: page.originalPNG, corners: nil)
        }
        if case .automatic = crop, page.isScan, !trim, !enhance {
            return Output(png: page.originalPNG, corners: nil)
        }
        let results = try await runBatch([page], crop: crop, enhance: enhance, trim: trim, detectOnly: detectOnly)
        return try results[0].get()
    }

    static func runBatch(_ pages: [ImportedPage], crop: Crop = .automatic, enhance: Bool = false,
                         trim: Bool = true, detectOnly: Bool = false) async throws -> [Result<Output, AppFailure>] {
        guard !pages.isEmpty else { return [] }
        guard let script = Bundle.main.url(forResource: "prepare_paper_notes", withExtension: "py"),
              let uv = executable() else {
            throw AppFailure.message(L("本地裁正需要 uv。可先使用原图。"))
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paper-notes-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let jobs = try pages.enumerated().map { index, page in
            let input = directory.appendingPathComponent("source-\(index).png")
            let output = directory.appendingPathComponent("prepared-\(index).png")
            try page.originalPNG.write(to: input)
            let parameters: (straighten: Bool, trim: Bool, corners: [[Double]]?)
            switch crop {
            case .automatic: parameters = (!page.isScan, trim, nil)
            case .entirePage: parameters = (false, false, nil)
            case .manual(let points): parameters = (true, trim, points.map { [$0.x, $0.y] })
            }
            return Job(source: input.path, output: output.path, straighten: parameters.straighten,
                       enhance: enhance, trim: parameters.trim, detectOnly: detectOnly, corners: parameters.corners)
        }
        let manifest = directory.appendingPathComponent("batch.json")
        try JSONEncoder().encode(jobs).write(to: manifest)
        // Use the same dependency cache across app bundles, even when the script moves.
        let args = ["run", "--no-project", "--python", "3.12", "--with-requirements", script.path,
                    "python", script.path, "--batch", manifest.path]
        let data = try await execute(uv, args: args, directory: directory)
        let reports = try JSONDecoder().decode([Report].self, from: data)
        guard reports.count == pages.count else { throw AppFailure.message(L("纸稿预处理结果不完整。")) }

        return reports.enumerated().map { index, report in
            if let error = report.error { return .failure(.message(L("本地预处理失败。%@", error))) }
            let corners = decodeCorners(report.corners)
            let png: Data
            if !detectOnly && (corners != nil || report.trimBounds != nil || enhance) {
                guard let prepared = try? Data(contentsOf: URL(fileURLWithPath: jobs[index].output)) else {
                    return .failure(.message(L("纸稿预处理结果不完整。")))
                }
                png = prepared
            } else {
                png = pages[index].originalPNG
            }
            return .success(Output(png: png, corners: corners,
                                   suggestions: (report.suggestions ?? []).compactMap { decodeCorners($0) },
                                   trimBounds: report.trimBounds))
        }
    }

    private static func execute(_ uv: URL, args: [String], directory: URL) async throws -> Data {
        let log = directory.appendingPathComponent("python.log")
        try Data().write(to: log)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        let process = Process()
        process.executableURL = uv
        process.arguments = args
        process.standardOutput = logHandle
        process.standardError = logHandle
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "OPENAI_API_KEY")
        process.environment = environment
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }

        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let last = text.split(separator: "\n").last.map(String.init)
        guard status == 0, let last else {
            throw AppFailure.message(L("本地预处理失败。%@", last ?? L("请检查 uv 和 Python 依赖。")))
        }
        return Data(last.utf8)
    }

    private static func decodeCorners(_ values: [[Double]]?) -> [PagePoint]? {
        guard let values, values.count == 4, values.allSatisfy({ $0.count == 2 }) else { return nil }
        return values.map { PagePoint(x: $0[0], y: $0[1]) }
    }

    private static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let standardPaths = [home.appendingPathComponent(".local/bin/uv").path, "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
        let environmentPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { String($0) + "/uv" }
        return (standardPaths + environmentPaths).first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
