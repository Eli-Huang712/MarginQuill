import AppKit
import ImageIO

enum RegionRecognitionKind: String, CaseIterable, Identifiable, Sendable {
    case formula, chart

    var id: Self { self }
    var title: String {
        switch self {
        case .formula: L("公式")
        case .chart: L("折线图")
        }
    }
}

struct PaddleRuntime {
    let directory: URL
    static let defaultDirectory = URL.applicationSupportDirectory
        .appending(path: "PaperNotes/Offline", directoryHint: .isDirectory)

    var python: URL { directory.appendingPathComponent("venv/bin/python") }
    var model: URL { directory.appendingPathComponent("paddleocr-vl-1.5-4bit", isDirectory: true) }
    var hasLayout: Bool {
        ["model.safetensors", "config.json"].allSatisfy {
            FileManager.default.isReadableFile(atPath: directory.appendingPathComponent("pp-doclayout-v3/" + $0).path)
        }
    }

    var isReady: Bool {
        let files = FileManager.default
        return files.isExecutableFile(atPath: python.path)
            && ["model.safetensors", "config.json", "tokenizer.json"]
                .allSatisfy { files.isReadableFile(atPath: model.appendingPathComponent($0).path) }
    }

    static func configured(_ path: String) -> Self? {
        let runtime = Self(directory: path.isEmpty ? defaultDirectory : URL(fileURLWithPath: path, isDirectory: true))
        return runtime.isReady ? runtime : nil
    }

    @MainActor
    static func chooseDirectory(_ current: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("选择目录")
        panel.directoryURL = current.isEmpty ? defaultDirectory : URL(fileURLWithPath: current, isDirectory: true)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

struct OfflineRegion: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let markdown: String
}

enum PaddleRecognition {
    private struct Result: Decodable {
        let markdown: String
    }

    static func recognize(png: Data, region: CGRect, kind: RegionRecognitionKind,
                          runtime: PaddleRuntime) async throws -> String {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AppFailure.message(L("无法读取图片。请选择照片或 PDF。"))
        }
        let selection = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !selection.isNull else { throw AppFailure.message(L("请框选包含内容的区域。")) }
        let pixels = CGRect(x: selection.minX * CGFloat(image.width), y: selection.minY * CGFloat(image.height),
                            width: selection.width * CGFloat(image.width), height: selection.height * CGFloat(image.height)).integral
        guard pixels.width >= 32, pixels.height >= 32, let crop = image.cropping(to: pixels) else {
            throw AppFailure.message(L("请框选包含内容的区域。"))
        }
        let output: Result = try await run(png: ImportedPage.encodePNG(crop), mode: kind.rawValue, runtime: runtime)
        return output.markdown
    }

    static func recognizeLayout(png: Data, runtime: PaddleRuntime) async throws -> [OfflineRegion] {
        try await run(png: png, mode: "auto", runtime: runtime)
    }

    private static func run<Output: Decodable>(png: Data, mode: String, runtime: PaddleRuntime) async throws -> Output {
        try Task.checkCancellation()
        guard let script = Bundle.main.url(forResource: "recognize_paddle_region", withExtension: "py") else {
            throw AppFailure.message(L("找不到 PaddleOCR-VL 识别脚本。"))
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("paper-region-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("region.png")
        let output = temp.appendingPathComponent("result.json")
        try png.write(to: input)
        let process = Process()
        process.executableURL = runtime.python
        process.currentDirectoryURL = temp
        process.arguments = [script.path, runtime.model.path, input.path, output.path, mode]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        for key in ["OPENAI_API_KEY", "HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "PYTHONHOME", "PYTHONPATH"] {
            environment.removeValue(forKey: key)
        }
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        process.environment = environment
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
        try Task.checkCancellation()
        guard status == 0 else {
            throw AppFailure.message(L("PaddleOCR-VL 未完成识别。请检查本机环境，或重新框选更清楚的区域。"))
        }
        return try JSONDecoder().decode(Output.self, from: Data(contentsOf: output))
    }
}
