import SwiftUI

struct SettingsView: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) var dismiss
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("OpenAI API").font(.title2.weight(.semibold))
            Text(workspace.hasKey ? "密钥已保存到钥匙串。可输入新密钥替换。" : "输入密钥后即可识别纸稿。密钥保存在钥匙串。")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            SecureField("API 密钥", text: $key)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("OpenAI API 密钥")
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                if workspace.hasKey {
                    Button("移除密钥", role: .destructive) {
                        do { try workspace.deleteKey() } catch { self.error = error.localizedDescription }
                    }
                }
                Spacer()
                Button("关闭", role: .cancel) { dismiss() }
                Button("保存") {
                    do {
                        try workspace.storeKey(key)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 430)
        .tint(PaperTheme.accent)
    }
}
