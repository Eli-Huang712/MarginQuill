import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

struct PagePoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    static let fullPage = [
        Self(x: 0, y: 0), Self(x: 1, y: 0), Self(x: 1, y: 1), Self(x: 0, y: 1)
    ]
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
            guard let tiff = page.thumbnail(of: size, for: .cropBox).tiffRepresentation else {
                throw AppFailure.message(L("无法生成扫描件预览。"))
            }
            let label = document.pageCount == 1 ? name : "\(name) · \(index + 1)"
            return Self(originalPNG: try normalize(tiff), name: label, isScan: true)
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
    }

    private struct Report: Decodable {
        let corners: [[Double]]?
        let suggestions: [[[Double]]]?
    }

    private struct VisionSeed: Encodable {
        let points: [[Double]]
        let confidence: Float
        let document: Bool
    }

    static func run(_ page: ImportedPage, crop: Crop = .automatic, enhance: Bool = false) async throws -> Output {
        switch crop {
        case .entirePage where !enhance, .automatic where page.isScan && !enhance:
            return Output(png: page.originalPNG, corners: nil)
        default: break
        }
        guard let script = Bundle.main.url(forResource: "prepare_paper_notes", withExtension: "py"),
              let uv = executable() else {
            throw AppFailure.message(L("本地裁正需要 uv。可先使用原图。"))
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paper-notes-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("source.png")
        let output = directory.appendingPathComponent("prepared.png")
        try page.originalPNG.write(to: input)

        var args = ["run", "--no-project", "--python", "3.12", "--script", script.path,
                    input.path, output.path, "--report"]
        switch crop {
        case .automatic where page.isScan, .entirePage:
            args.append("--no-rectify")
        case .manual(let points):
            args += ["--corners"] + points.flatMap { [String($0.x), String($0.y)] }
        case .automatic:
            let seeds = visionSeeds(page.originalPNG)
            if !seeds.isEmpty {
                let seedFile = directory.appendingPathComponent("vision.json")
                try JSONEncoder().encode(seeds).write(to: seedFile)
                args += ["--vision-seeds", seedFile.path]
            }
        }
        if enhance { args.append("--enhance") }

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
        let report = try JSONDecoder().decode(Report.self, from: Data(last.utf8))
        return Output(png: try Data(contentsOf: output), corners: decodeCorners(report.corners),
                      suggestions: (report.suggestions ?? []).compactMap { decodeCorners($0) })
    }

    private static func decodeCorners(_ values: [[Double]]?) -> [PagePoint]? {
        guard let values, values.count == 4, values.allSatisfy({ $0.count == 2 }) else { return nil }
        return values.map { PagePoint(x: $0[0], y: $0[1]) }
    }

    private static func visionSeeds(_ data: Data) -> [VisionSeed] {
        let document = VNDetectDocumentSegmentationRequest()
        let rectangles = VNDetectRectanglesRequest()
        rectangles.minimumSize = 0.20
        rectangles.minimumAspectRatio = 0.37
        rectangles.minimumConfidence = 0.45
        rectangles.quadratureTolerance = 42
        rectangles.maximumObservations = 5
        let handler = VNImageRequestHandler(data: data)
        // A failure in one request leaves the other detector and OpenCV available.
        try? handler.perform([document])
        try? handler.perform([rectangles])
        return (document.results ?? []).map { seed($0, document: true) }
            + (rectangles.results ?? []).map { seed($0, document: false) }
    }

    private static func seed(_ observation: VNRectangleObservation, document: Bool) -> VisionSeed {
        let points = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
        return VisionSeed(points: points.map { [Double($0.x), 1 - Double($0.y)] },
                          confidence: observation.confidence, document: document)
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
