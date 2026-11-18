import Darwin
import Foundation
import Security

struct APIKeyFile {
    static let local = Self(url: URL.applicationSupportDirectory
        .appending(path: "PaperNotes", directoryHint: .isDirectory).appending(path: ".env"))

    let url: URL
    private static let entry = "OPENAI_API_KEY="
    private static let maximumKeyLength = 4096
    private static let fileMode: mode_t = 0o600

    func load() -> String? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == geteuid(), attributes.st_mode & 0o077 == 0,
              let data = try? file.read(upToCount: 8193), data.count <= 8192,
              let text = String(data: data, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(Self.entry) }) else {
            return nil
        }
        let key = String(line.dropFirst(Self.entry.count))
        return Self.isValid(key) ? key : nil
    }

    func save(_ raw: String) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AppFailure.message(L("请输入 API 密钥。")) }
        guard Self.isValid(key) else { throw AppFailure.message(L("API 密钥必须为一行，且不能含空格。")) }

        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".env.\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, Self.fileMode)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { _ = Darwin.unlink(temporary.path) }

            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close() }
            guard fchmod(descriptor, Self.fileMode) == 0 else { throw CocoaError(.fileWriteNoPermission) }
            try file.write(contentsOf: Data((Self.entry + key + "\n").utf8))
            try file.synchronize()
            guard Darwin.rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            throw AppFailure.message(L("无法保存本地密钥文件。请检查目录权限。"))
        }
    }

    func remove() throws {
        guard Darwin.unlink(url.path) == 0 || errno == ENOENT else {
            throw AppFailure.message(L("无法移除本地密钥文件。"))
        }
    }

    private static func isValid(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= maximumKeyLength && key.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }
}

enum LegacyAPIKey {
    static func readForMigration() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.paperfolio.paper-notes",
            kSecAttrAccount as String: "openai",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { throw AppFailure.message(L("钥匙串中没有找到旧版密钥。")) }
        guard status == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw AppFailure.message(L("无法读取旧版密钥。可以直接粘贴并保存密钥。"))
        }
        return key
    }
}
