import EventKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PreferenceKey.language) private var language = InterfaceLanguage.system
    @AppStorage(PreferenceKey.appearance) private var appearance = AppAppearance.system
    @AppStorage(PreferenceKey.accent) private var accent = AppAccent.purple
    @AppStorage(PreferenceKey.model) private var defaultModel = RecognitionModel.terra
    @AppStorage(PreferenceKey.tokenUsage) private var showsTokenUsage = true
    @AppStorage(PreferenceKey.paddleDirectory) private var paddleDirectory = ""
    @State private var key = ""
    @State private var keyMessage: String?
    @State private var keyFailed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("设置")).font(.title2.weight(.semibold))
                Spacer()
                Button(L("完成")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 19)
            .frame(height: 52)
            Divider()
            HStack(spacing: 0) {
                navigation
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    Text(workspace.settingsSection.title)
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.top, 17)
                    Form { selectedSettings }
                        .formStyle(.grouped)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 670, height: 430)
        .background(PaperTheme.surface)
        .tint(accent.color)
    }

    private var navigation: some View {
        VStack(spacing: 3) {
            ForEach(SettingsSection.allCases) { section in
                let selected = workspace.settingsSection == section
                Button {
                    workspace.settingsSection = section
                } label: {
                    Label(section.title, systemImage: section.icon)
                        .font(.body.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? accent.color : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 9)
                        .background(selected ? accent.color.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 165)
    }

    @ViewBuilder
    private var selectedSettings: some View {
        switch workspace.settingsSection {
        case .general:
            Section(L("语言")) {
                Picker(L("界面语言"), selection: $language) {
                    ForEach(InterfaceLanguage.allCases) { Text($0.label).tag($0) }
                }
                Text(L("重新打开纸笺后生效。笔记保留原文语言。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .appearance:
            Section(L("主题")) {
                Picker(L("显示模式"), selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                Picker(L("强调色"), selection: $accent) {
                    ForEach(AppAccent.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                HStack(spacing: 8) {
                    Circle().fill(accent.color).frame(width: 11, height: 11)
                    Text(L("强调色预览")).foregroundStyle(accent.color)
                }
                .accessibilityHidden(true)
            }
        case .recognition:
            Section("OpenAI API") {
                VStack(alignment: .leading, spacing: 8) {
                    Label(workspace.hasKey ? L("密钥已保存到本机") : L("尚未设置密钥"),
                          systemImage: workspace.hasKey ? "checkmark.circle" : "key")
                        .foregroundStyle(.secondary)
                    SecureField(L("OpenAI API 密钥"), text: $key)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        if workspace.hasKey {
                            Button(L("移除密钥"), role: .destructive) {
                                updateKey(L("密钥已移除")) { try workspace.deleteKey() }
                            }
                        } else {
                            Button(L("从钥匙串迁移…")) {
                                updateKey(L("密钥已迁移到本机")) { try workspace.migrateKeyFromKeychain() }
                            }
                            .help(L("从旧版钥匙串复制密钥，可能需要验证一次。"))
                        }
                        Spacer()
                        Button(L("保存密钥")) {
                            updateKey(L("密钥已保存")) { try workspace.storeKey(key) }
                        }
                            .buttonStyle(.borderedProminent)
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text(L("本地 .env 文件仅当前账户可读写。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let keyMessage {
                        Text(keyMessage).font(.caption)
                            .foregroundStyle(keyFailed ? Color.red : Color.secondary)
                    }
                }
            }
            Section(L("识别")) {
                Picker(L("默认模型"), selection: $defaultModel) {
                    ForEach(RecognitionModel.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: defaultModel) { _, selected in
                    if workspace.record == nil, workspace.pages.isEmpty, !workspace.isWorking {
                        workspace.model = selected
                    }
                }
                Text(L("用于新建笔记。已有记录保留原来的模型。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("用量")) {
                Toggle(L("在状态栏显示 Token 用量"), isOn: $showsTokenUsage)
            }
            Section(L("离线识别")) {
                let runtime = PaddleRuntime.configured(paddleDirectory)
                Text(L("Apple Vision 转录文字和表格。准备好版面模型后，PaddleOCR-VL 自动补识别公式和折线图。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Label(runtime == nil ? L("PaddleOCR-VL 尚未配置")
                          : (runtime?.hasLayout == true ? L("PaddleOCR-VL 自动与框选识别已就绪") : L("PaddleOCR-VL 框选识别已就绪")),
                          systemImage: runtime == nil ? "folder" : "checkmark.circle")
                    Spacer()
                    Button(L("选择模型目录…")) {
                        if let path = PaddleRuntime.chooseDirectory(paddleDirectory) { paddleDirectory = path }
                    }
                }
                if !paddleDirectory.isEmpty {
                    Text(paddleDirectory)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(paddleDirectory)
                }
                Text(L("目录内应包含 venv 和 paddleocr-vl-1.5-4bit。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .integrations:
            Section(L("苹果系统服务")) {
                integration(L("提醒事项"), icon: "checklist", entity: .reminder,
                            detail: L("将确认过的待办加入你选定的列表。"))
                integration(L("日历"), icon: "calendar", entity: .event,
                            detail: L("将确认过的日程加入系统默认日历。"))
            }
        }
    }

    private func integration(_ title: String, icon: String, entity: EKEntityType, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: icon)
                    .font(.body.weight(.medium))
                Spacer()
                Text(permission(entity)).font(.caption).foregroundStyle(.secondary)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func permission(_ entity: EKEntityType) -> String {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .fullAccess: L("已授权")
        case .writeOnly: L("仅写入")
        case .denied, .restricted: L("权限关闭")
        default: L("按需授权")
        }
    }

    private func updateKey(_ success: String, perform: () throws -> Void) {
        do {
            try perform()
            key = ""
            keyFailed = false
            keyMessage = success
        } catch {
            keyFailed = true
            keyMessage = error.localizedDescription
        }
    }
}
