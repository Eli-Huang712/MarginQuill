import Foundation
import Security

enum RecognitionModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case terra = "gpt-6.1-terra"
    case luna = "gpt-6-luna"

    var id: String { rawValue }
    var label: String { self == .terra ? "GPT-6.1 Terra" : "GPT-6 Luna" }
}

enum AppFailure: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.paperfolio.paper-notes",
        kSecAttrAccount as String: "openai"
    ]

    static func load() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) throws {
        let secret = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, secret as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(secret) { _, new in new } as CFDictionary, nil)
        }
        if status != errSecSuccess {
            throw AppFailure.message("无法保存到钥匙串（\(status)）。")
        }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppFailure.message("无法删除钥匙串中的密钥（\(status)）。")
        }
    }
}

struct APIUsage: Codable {
    let inputTokens: Int?
    let outputTokens: Int?
}

struct RecognitionResult {
    let markdown: String
    let issues: [ReviewItem]
    let todos: [PaperTodo]
    let usage: APIUsage
}

struct RecognitionClient {
    var session: URLSession = .shared

    func recognize(png: Data, model: RecognitionModel, key: String, prompt: String) async throws -> RecognitionResult {
        let request = try makeRequest(png: png, model: model, key: key, prompt: prompt)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AppFailure.message("没有收到有效的 API 响应。")
        }
        return try parseResponse(data, status: response.statusCode)
    }

    func makeRequest(png: Data, model: RecognitionModel, key: String, prompt: String) throws -> URLRequest {
        let content: [[String: String]] = [
            ["type": "input_text", "text": prompt],
            ["type": "input_image", "image_url": "data:image/png;base64," + png.base64EncodedString()]
        ]
        let payload: [String: Any] = [
            "model": model.rawValue,
            "input": [["role": "user", "content": content]],
            "reasoning": ["effort": "low"],
            "max_output_tokens": 6000,
            "store": false,
            "text": ["format": Self.outputFormat]
        ]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private static let boxSchema: [String: Any] = [
        "type": ["object", "null"], "required": ["x", "y", "width", "height"],
        "additionalProperties": false,
        "properties": [
            "x": ["type": "number"], "y": ["type": "number"],
            "width": ["type": "number"], "height": ["type": "number"]
        ]
    ]

    private static let outputFormat: [String: Any] = [
        "type": "json_schema", "name": "paper_note_page", "strict": true,
        "schema": [
            "type": "object", "required": ["markdown", "issues", "todos"], "additionalProperties": false,
            "properties": [
                "markdown": ["type": "string"],
                "issues": [
                    "type": "array",
                    "items": [
                        "type": "object", "required": ["category", "location", "detail", "anchor", "box"],
                        "additionalProperties": false,
                        "properties": [
                            "category": ["type": "string"], "location": ["type": "string"],
                            "detail": ["type": "string"],
                            "anchor": ["type": ["string", "null"]],
                            "box": boxSchema
                        ]
                    ]
                ],
                "todos": [
                    "type": "array",
                    "items": [
                        "type": "object", "required": ["title", "dueText", "date", "anchor", "box"],
                        "additionalProperties": false,
                        "properties": [
                            "title": ["type": "string"],
                            "dueText": ["type": ["string", "null"]],
                            "date": ["type": ["string", "null"]],
                            "anchor": ["type": ["string", "null"]],
                            "box": boxSchema
                        ]
                    ]
                ]
            ]
        ]
    ]

    private struct PageContent: Decodable {
        struct Item: Decodable {
            let category: String
            let location: String
            let detail: String
            let anchor: String?
            let box: ReviewBox?
        }
        let markdown: String
        let issues: [Item]
        let todos: [Todo]?

        struct Todo: Decodable {
            let title: String
            let dueText: String?
            let date: String?
            let anchor: String?
            let box: ReviewBox?
        }
    }

    private struct Envelope: Decodable {
        struct Item: Decodable {
            struct Segment: Decodable {
                let type: String
                let text: String?
            }
            let type: String
            let content: [Segment]?
        }
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
        }
        let status: String?
        let output: [Item]?
        let usage: Usage?
    }

    func parseResponse(_ data: Data, status: Int) throws -> RecognitionResult {
        switch status {
        case 200..<300: break
        case 400: throw AppFailure.message("API 无法处理这张图或该模型参数（400）。")
        case 401, 403: throw AppFailure.message("请检查 API 密钥以及该项目的模型权限（\(status)）。")
        case 429: throw AppFailure.message("API 额度不足或请求太频繁（429）。请检查用量后重试。")
        default: throw AppFailure.message("OpenAI API 返回 \(status)。请稍后重试。")
        }
        let result = try JSONDecoder().decode(Envelope.self, from: data)
        if result.status == "incomplete" {
            throw AppFailure.message("识别结果未完整返回。可裁取较密的部分后重试。")
        }
        guard result.status == "completed" else {
            throw AppFailure.message("API 未完成识别。请稍后重试。")
        }
        let text = (result.output ?? [])
            .filter { $0.type == "message" }
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let content = try? JSONDecoder().decode(PageContent.self, from: Data(text.utf8)) else {
            throw AppFailure.message("API 没有返回符合格式的识别结果。")
        }
        let issues = content.issues.map {
            ReviewItem(category: $0.category, location: $0.location, detail: $0.detail,
                       anchor: $0.anchor, box: $0.box)
        }
        let todos = (content.todos ?? []).compactMap { todo -> PaperTodo? in
            let title = todo.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let date = todo.date.flatMap(ReminderDay.init(iso:))
            return PaperTodo(title: title, dueText: todo.dueText,
                             date: date.flatMap { $0.matchesPrintedDate(in: todo.dueText) ? $0 : nil },
                             anchor: todo.anchor, box: todo.box)
        }
        return RecognitionResult(markdown: content.markdown.trimmingCharacters(in: .whitespacesAndNewlines),
                                 issues: issues, todos: todos, usage: APIUsage(inputTokens: result.usage?.input_tokens,
                                                                outputTokens: result.usage?.output_tokens))
    }
}
