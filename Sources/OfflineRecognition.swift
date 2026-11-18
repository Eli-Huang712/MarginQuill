import Foundation
import CoreML
import ImageIO
import Vision

enum RecognitionEngine: String, Codable, Sendable {
    case cloud, vision, paddle, visionAndPaddle

    var label: String {
        switch self {
        case .cloud: "OpenAI"
        case .vision: "Apple Vision"
        case .paddle: "PaddleOCR-VL"
        case .visionAndPaddle: "Apple Vision + PaddleOCR-VL"
        }
    }
}

enum VisionRecognition {
    struct Block {
        let box: CGRect
        let markdown: String
    }

    struct Page {
        let text: [Block]
        let tables: [Block]

        func render(with regions: [OfflineRegion]) -> (RecognitionResult, RecognitionEngine) {
            let supplements = regions.map { region in
                let box = CGRect(x: region.x, y: 1 - region.y - region.height,
                                 width: region.width, height: region.height)
                return Block(box: box, markdown: region.markdown)
            }.filter { block in
                !tables.contains { $0.box.contains(CGPoint(x: block.box.midX, y: block.box.midY)) }
            }
            let structured = tables + supplements
            let lines = text.filter { line in
                let center = CGPoint(x: line.box.midX, y: line.box.midY)
                return !structured.contains(where: { $0.box.contains(center) })
            }
            let markdown = (lines + structured).sorted {
                if $0.box.midY != $1.box.midY { return $0.box.midY > $1.box.midY }
                return $0.box.minX < $1.box.minX
            }.map(\.markdown).joined(separator: "\n\n")
            let review = ReviewItem(category: L("核对原稿图形与公式"), location: "",
                                    detail: L("请对照原图核对框图、公式和图表。自动识别遗漏的公式与折线图可框选重识别。"),
                                    showsOriginal: true)
            let result = RecognitionResult(markdown: markdown, issues: [review], todos: [], events: [],
                                           usage: APIUsage(inputTokens: nil, outputTokens: nil))
            return (result, supplements.isEmpty ? .vision : .visionAndPaddle)
        }
    }

    static func recognize(png: Data) async throws -> Page {
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateWithData(png as CFData, nil)
                .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else {
            throw AppFailure.message(L("无法读取图片。请选择照片或 PDF。"))
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        // Keep the fallback independent of the Neural Engine's first-use model compilation.
        for (stage, devices) in (try? request.supportedComputeStageDevices) ?? [:] {
            if let cpu = devices.first(where: isCPU) { request.setComputeDevice(cpu, for: stage) }
        }
        try VNImageRequestHandler(cgImage: image).perform([request])
        var tables: [Block] = []
        if #available(macOS 26.0, *) {
            // Text remains available if the optional layout request fails.
            tables = (try? await detectTables(image)) ?? []
        }
        try Task.checkCancellation()
        let text = (request.results ?? []).compactMap { line -> Block? in
            let box = line.boundingBox
            guard let words = line.topCandidates(1).first?.string else { return nil }
            return Block(box: box, markdown: MarkdownTable.literal(words))
        }
        return Page(text: text, tables: tables)
    }

    @available(macOS 26.0, *)
    private static func detectTables(_ image: CGImage) async throws -> [Block] {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.recognitionLanguages = [
            Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en-US")
        ]
        request.textRecognitionOptions.useLanguageCorrection = false
        for (stage, devices) in request.supportedComputeStageDevices {
            if let cpu = devices.first(where: isCPU) { request.setComputeDevice(cpu, for: stage) }
        }
        let observations = try await request.perform(on: image)
        return observations.flatMap { $0.document.tables }.compactMap { table in
            let rows = table.rows.map { row in
                (0..<table.columns.count).map { column in
                    row.first { $0.columnRange.lowerBound == column }?.content.text.transcript ?? ""
                }
            }
            guard let markdown = MarkdownTable.render(rows) else { return nil }
            return Block(box: table.boundingRegion.boundingBox.cgRect, markdown: markdown)
        }
    }

    private static func isCPU(_ device: MLComputeDevice) -> Bool {
        if case .cpu = device { return true }
        return false
    }
}

enum MarkdownTable {
    static func literal(_ text: String) -> String {
        let value = text.components(separatedBy: .newlines).joined(separator: " ")
        return value.reduce(into: "") { result, character in
            if "\\`*_{}[]()#+-.!|<>".contains(character) { result += "\\" }
            result.append(character)
        }.trimmingCharacters(in: .whitespaces)
    }

    static func render(_ cells: [[String]]) -> String? {
        guard cells.count >= 2, let width = cells.first?.count, width >= 2,
              cells.allSatisfy({ $0.count == width }),
              cells.contains(where: { $0.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) })
        else { return nil }
        func row(_ fields: [String]) -> String { "| " + fields.joined(separator: " | ") + " |" }
        var lines = cells.map { row($0.map(literal)) }
        lines.insert(row(Array(repeating: "---", count: width)), at: 1)
        return lines.joined(separator: "\n")
    }
}
