import AppKit
import SwiftUI

enum PaperTheme {
    static let nativeAccent = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? NSColor(srgbRed: 0.68, green: 0.61, blue: 1, alpha: 1)
                    : NSColor(srgbRed: 0.40, green: 0.31, blue: 0.80, alpha: 1)
    }
    static let accent = Color(nsColor: nativeAccent)
    static let divider = Color(nsColor: .separatorColor).opacity(0.62)
    static let surface = Color(nsColor: .windowBackgroundColor)
}

struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace
    var capture: CaptureButton
    @AppStorage("showsReviewSidebar") private var showingReview = true
    @State private var cropPage: PaperPage?
    @State private var focus: PreviewFocus?
    @State private var focusedPhoto: NSImage?
    @State private var showingResolved = false
    @State private var dropTargeted = false
    @State private var inspectOriginal = false

    var body: some View {
        VStack(spacing: 0) {
            workArea
            Divider()
            statusBar
        }
        .background(PaperTheme.surface)
        .tint(PaperTheme.accent)
        .sheet(isPresented: $workspace.showingSettings) { SettingsView(workspace: workspace) }
        .sheet(item: $cropPage) { page in CropEditor(workspace: workspace, page: page) }
        .onChange(of: workspace.record?.id) { _, _ in
            clearFocus()
            showingResolved = false
        }
        .onChange(of: workspace.selectedPageID) { _, selected in
            inspectOriginal = false
            if focus?.page != selected { clearFocus() }
        }
    }

    private var workArea: some View {
        GeometryReader { geometry in
            let docked = geometry.size.width >= 1175
            HStack(spacing: 0) {
                if workspace.showingHistory && docked {
                    historyPane(docked: true)
                    Divider()
                }
                HSplitView {
                    sourcePane
                        .frame(minWidth: 306, idealWidth: 322, maxWidth: 350, maxHeight: .infinity)
                        .layoutPriority(1)
                    documentPane
                        .frame(minWidth: 385, maxWidth: .infinity, maxHeight: .infinity)
                    if showingReview {
                        reviewPane
                            .frame(minWidth: 245, idealWidth: 260, maxWidth: 280, maxHeight: .infinity)
                            .layoutPriority(1)
                    }
                }
            }
            .overlay(alignment: .leading) {
                if workspace.showingHistory && !docked {
                    historyPane(docked: false)
                        .overlay(alignment: .trailing) { Divider() }
                        .shadow(color: .black.opacity(0.20), radius: 9, x: 4)
                }
            }
        }
    }

    private func historyPane(docked: Bool) -> some View {
        HistorySidebar(workspace: workspace) {
            if !docked { workspace.showingHistory = false }
        }
        .frame(width: 213)
        .frame(maxHeight: .infinity)
        .background(PaperTheme.surface)
    }

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("纸稿").font(.headline)
                if !workspace.pages.isEmpty {
                    Text("\(workspace.pages.count) 页")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                PhoneCaptureControl(button: capture, isEnabled: !workspace.isWorking)
                    .frame(width: 121, height: 28)
            }
            .padding(.horizontal, 15)
            .frame(height: 47)
            Divider()

            VStack(alignment: .leading, spacing: 13) {
                if !workspace.pages.isEmpty {
                    pageStrip
                    pageTools
                }
                pageCanvas

                if let page = workspace.selectedPage {
                    HStack {
                        Text(page.source.name).font(.caption).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 5)
                        Text(inspectOriginal ? "原图" : (page.appliedCorners == nil ? "完整画面" : "裁正后"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                recognitionControls
            }
            .padding([.horizontal, .bottom], 15)
            .padding(.top, 9)
        }
        .background(PaperTheme.surface)
    }

    private var pageStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(Array(workspace.pages.enumerated()), id: \.element.id) { index, page in
                    thumbnail(page, index: index)
                }
            }
            .padding(2)
        }
        .scrollIndicators(.hidden)
    }

    private func thumbnail(_ page: PaperPage, index: Int) -> some View {
        let selected = workspace.selectedPageID == page.id
        return Button {
            workspace.selectedPageID = page.id
        } label: {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
                if let image = page.image {
                    Image(nsImage: image).resizable().scaledToFit().padding(4)
                }
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .padding(3)
            }
            .frame(width: 61, height: 62)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? PaperTheme.accent : PaperTheme.divider, lineWidth: selected ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(index + 1) 页，\(page.source.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .draggable(page.id.uuidString)
        .dropDestination(for: String.self) { values, _ in
            guard let raw = values.first, let moving = UUID(uuidString: raw), !workspace.isWorking else { return false }
            workspace.movePage(moving, to: page.id)
            return true
        }
    }

    private var pageTools: some View {
        HStack(spacing: 6) {
            if let page = workspace.selectedPage, let index = workspace.selectedIndex {
                pageAction("arrow.left", label: "前移选中页") { workspace.movePage(page.id, by: -1) }
                    .disabled(index == 0 || workspace.isWorking)
                pageAction("arrow.right", label: "后移选中页") { workspace.movePage(page.id, by: 1) }
                    .disabled(index + 1 == workspace.pages.count || workspace.isWorking)
                pageAction("minus", label: "移除选中页") { workspace.removePage(page.id) }
                    .disabled(workspace.isWorking)
                Spacer(minLength: 5)
                Button { cropPage = page } label: { Label("调整角点", systemImage: "crop") }
                    .disabled(workspace.isWorking)
            }
        }
        .controlSize(.small)
    }

    private func pageAction(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 15, height: 14) }
            .help(label).accessibilityLabel(label)
    }

    private var pageCanvas: some View {
        ZStack(alignment: .topTrailing) {
            Color(nsColor: .controlBackgroundColor)
            if let selected = workspace.selectedPage,
               let photo = inspectOriginal ? selected.originalImage : (focusedPhoto ?? selected.image) {
                PaperImage(
                    photo: photo,
                    annotation: inspectOriginal || focusedPhoto == nil ? nil : focusedItem?.box?.visibleRect,
                    number: focus.flatMap { reviewNumbers[$0.issue] }
                )
                if selected.preparedImage != nil {
                    Button(inspectOriginal ? "查看处理后" : "查看原图") { inspectOriginal.toggle() }
                    .controlSize(.small)
                    .padding(8)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 37, weight: .light)).foregroundStyle(PaperTheme.accent)
                        .accessibilityHidden(true)
                    Text("拖入纸稿").font(.subheadline.weight(.medium))
                    Text("可一次导入多张照片")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minHeight: 145, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(dropTargeted ? PaperTheme.accent : PaperTheme.divider,
                              lineWidth: dropTargeted ? 2 : 1)
                .allowsHitTesting(false)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !workspace.isWorking, !files.isEmpty else { return false }
            workspace.load(urls: files)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var recognitionControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("识别模型").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("识别模型", selection: $workspace.model) {
                    ForEach(RecognitionModel.allCases) { model in Text(model.label).tag(model) }
                }
                .labelsHidden().frame(width: 133).disabled(workspace.isRecognizing)
            }
            if workspace.isRecognizing {
                Button(action: workspace.cancelRecognition) {
                    Label("停止识别", systemImage: "stop.circle").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            } else {
                Button(action: workspace.recognize) {
                    Label(recognizeLabel, systemImage: "text.viewfinder").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(workspace.pages.isEmpty || workspace.isPreparing)
                .help("按左上方的页序识别纸稿")
            }
        }
    }

    private var recognizeLabel: String {
        if let record = workspace.record, workspace.canResume,
           record.model == workspace.model, record.completedCount > 0 {
            return "继续识别 \(record.pages.count - record.completedCount) 页"
        }
        if workspace.pages.isEmpty { return "识别纸稿" }
        return "识别 \(workspace.pages.count) 页"
    }

    private var documentPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("文档").font(.headline)
                Spacer()
                if workspace.record != nil {
                    Button {
                        workspace.showingSource.toggle()
                    } label: {
                        Label(workspace.showingSource ? "显示预览" : "还原源码",
                              systemImage: workspace.showingSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
                    }
                    .disabled(workspace.isRecognizing)
                }
                Button(action: workspace.copy) { Image(systemName: "document.on.document") }
                    .help("复制 Markdown").accessibilityLabel("复制 Markdown")
                    .disabled(workspace.markdown.isEmpty)
                Button(action: workspace.export) { Label("导出…", systemImage: "square.and.arrow.up") }
                    .disabled(workspace.markdown.isEmpty)
                if !showingReview {
                    Button {
                        showingReview = true
                    } label: {
                        HStack(spacing: 5) {
                            Label("待核对", systemImage: "sidebar.right")
                            reviewCountBadge
                        }
                    }
                    .help("展开待核对侧栏")
                    .accessibilityLabel("展开待核对侧栏")
                    .accessibilityValue("\(reviewCount) 项待核对")
                }
            }
            .padding(.horizontal, 15)
            .frame(height: 47)
            Divider()
            ZStack {
                Color(nsColor: .textBackgroundColor)
                if workspace.showingSource {
                    TextEditor(text: Binding(get: { workspace.markdown }, set: { workspace.editMarkdown($0) }))
                        .font(.system(size: 13, design: .monospaced))
                        .lineSpacing(4)
                        .scrollContentBackground(.hidden)
                        .padding(16)
                        .disabled(workspace.isRecognizing)
                        .accessibilityLabel("Markdown 源码编辑区")
                } else if !workspace.markdown.isEmpty {
                    MarkdownPreview(sections: previewSections, annotations: previewAnnotations,
                                    focus: focus, openAnnotation: openAnnotation)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 39, weight: .ultraLight))
                            .foregroundStyle(PaperTheme.accent)
                            .accessibilityHidden(true)
                        Text("文档预览").font(.headline)
                        Text(workspace.record != nil && !workspace.isRecognizing && !workspace.canResume
                             ? "可在源码中补录正文。" : "识别后在这里阅读正文和框图。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var previewSections: [PreviewSection] {
        guard let record = workspace.record else { return [] }
        if let edited = record.editedMarkdown { return [PreviewSection(id: "document", markdown: edited)] }
        return record.pages.compactMap { page in
            page.markdown.map { PreviewSection(id: page.id.uuidString, markdown: $0) }
        }
    }

    private var reviewCount: Int {
        workspace.record?.pages.reduce(0) { $0 + $1.issues.filter { !$0.resolved }.count } ?? 0
    }

    @ViewBuilder
    private var reviewCountBadge: some View {
        let count = reviewCount
        if count > 0 {
            Text("\(count)").font(.caption.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(PaperTheme.accent.opacity(0.13), in: Capsule())
                .foregroundStyle(PaperTheme.accent)
        }
    }

    private var reviewNumbers: [UUID: Int] {
        let items = workspace.record?.pages.flatMap(\.issues) ?? []
        return Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset + 1) })
    }

    private var focusedItem: ReviewItem? {
        guard let focus else { return nil }
        return workspace.record?.pages.first(where: { $0.id == focus.page })?.issues
            .first { $0.id == focus.issue }
    }

    private var previewAnnotations: [PreviewAnnotation] {
        guard let record = workspace.record else { return [] }
        let numbers = reviewNumbers
        return record.pages.flatMap { page in
            let section = record.editedMarkdown == nil ? page.id.uuidString : "document"
            return page.issues.filter { !$0.resolved }.compactMap { item in
                numbers[item.id].map { number in
                    PreviewAnnotation(id: item.id, section: section, number: number,
                                      category: item.category, anchor: item.anchor)
                }
            }
        }
    }

    private func openAnnotation(_ id: UUID) {
        guard let page = workspace.record?.pages.first(where: { $0.issues.contains { $0.id == id } }) else { return }
        workspace.showIssuePage(page.id)
        inspectOriginal = false
        focusedPhoto = workspace.recognizedImage(for: page.id)
        focus = PreviewFocus(page: page.id, issue: id)
        showingReview = true
    }

    private func clearFocus() {
        focus = nil
        focusedPhoto = nil
    }

    private var reviewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "checklist").foregroundStyle(PaperTheme.accent).accessibilityHidden(true)
                Text("待核对").font(.headline)
                reviewCountBadge
                Spacer()
                Button {
                    showingReview = false
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("收起待核对侧栏")
                .accessibilityLabel("收起待核对侧栏")
            }
            .padding(.horizontal, 15).frame(height: 47)
            Divider()
            if let record = workspace.record {
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            let resolved = record.pages.flatMap(\.issues).contains { $0.resolved }
                            if resolved {
                                Toggle("显示已处理", isOn: $showingResolved)
                                    .toggleStyle(.checkbox).font(.caption)
                            }
                            ForEach(Array(record.pages.enumerated()), id: \.element.id) { index, page in
                                if let error = page.error {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("第 \(index + 1) 页 · 识别暂停").font(.subheadline.weight(.semibold))
                                        Text(error).font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(PaperTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                                }
                                ForEach(page.issues.filter { showingResolved || !$0.resolved }) { item in
                                    issueCard(item, page: page, index: index)
                                        .id(item.id)
                                }
                            }
                            if reviewCount == 0 && !record.pages.contains(where: { $0.error != nil }) &&
                                !(resolved && showingResolved) {
                                Text(workspace.isRecognizing ? "等待识别结果…" :
                                        (record.completedCount == 0 ? "识别后的疑点会显示在这里。" : "已完成页面没有待核对项。"))
                                    .font(.callout).foregroundStyle(.secondary)
                                    .padding(.top, 3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    }
                    .onChange(of: focus, initial: true) { _, selected in
                        if let selected { scroll.scrollTo(selected.issue, anchor: .center) }
                    }
                }
            } else {
                Text("点开疑点，即可查看对应的纸稿。")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(15)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(PaperTheme.surface)
    }

    private func issueCard(_ item: ReviewItem, page: NoteRecord.Page, index: Int) -> some View {
        let selected = focus?.issue == item.id
        let number = reviewNumbers[item.id] ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                openAnnotation(item.id)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("\(number)")
                            .font(.caption.weight(.semibold)).monospacedDigit()
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(PaperTheme.accent.opacity(0.13), in: Capsule())
                        Text("第 \(index + 1) 页 · \(item.category)")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(PaperTheme.accent)
                    if !item.location.isEmpty {
                        Text(item.location).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(item.detail).font(.callout).foregroundStyle(.primary)
                    if selected, item.box?.visibleRect != nil, focusedPhoto != nil, !inspectOriginal {
                        Text("已标出原稿大致位置").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("定位到第 \(index + 1) 张纸稿")
            Button {
                workspace.markIssue(item.id, page: page.id, resolved: !item.resolved)
                if selected && !item.resolved { clearFocus() }
            } label: {
                Label(item.resolved ? "恢复待核对" : "标为已处理",
                      systemImage: item.resolved ? "arrow.uturn.backward" : "checkmark")
            }
            .buttonStyle(ReviewActionButtonStyle())
            .disabled(workspace.isRecognizing)
        }
        .padding(10)
        .background(selected ? PaperTheme.accent.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selected ? PaperTheme.accent.opacity(0.70) : PaperTheme.divider)
                .allowsHitTesting(false)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if workspace.isWorking { ProgressView().controlSize(.small) }
            if let error = workspace.error {
                Label(error, systemImage: "exclamationmark.circle").lineLimit(1)
            } else if workspace.imagesChanged, workspace.record != nil, !workspace.isWorking {
                Text("纸稿已调整，下次识别会建立新记录。").lineLimit(1)
            } else {
                Text(workspace.notice).lineLimit(1)
            }
            Spacer()
            if let usage = workspace.record?.usage, let input = usage.inputTokens, let output = usage.outputTokens {
                Text("输入 \(input.formatted()) · 输出 \(output.formatted()) tokens").monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 29)
    }
}

private struct ReviewActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Appearance(configuration: configuration)
    }

    private struct Appearance: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 6)
            let fill = configuration.isPressed ? 0.27 : (isHovered ? 0.18 : 0.075)
            let outline = configuration.isPressed || isHovered ? 0.58 : 0.23
            configuration.label
                .font(.caption.weight(.medium))
                .foregroundStyle(isEnabled ? PaperTheme.accent : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(PaperTheme.accent.opacity(isEnabled ? fill : 0.045), in: shape)
                .overlay {
                    shape.strokeBorder(PaperTheme.accent.opacity(isEnabled ? outline : 0.12))
                        .allowsHitTesting(false)
                }
                .contentShape(shape)
                .onHover { isHovered = $0 }
        }
    }
}

struct HistorySidebar: View {
    @ObservedObject var workspace: Workspace
    var afterOpening: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("历史记录")
                .font(.headline)
                .padding(.horizontal, 14)
                .frame(height: 47, alignment: .leading)
            Divider()
            if workspace.history.isEmpty {
                Text("还没有记录").font(.callout).foregroundStyle(.secondary).padding(14)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(workspace.history) { entry in row(entry) }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ entry: NoteRecord) -> some View {
        let selected = workspace.record?.id == entry.id
        return HStack(spacing: 2) {
            Button {
                workspace.openHistory(entry.id)
                if workspace.record?.id == entry.id { afterOpening() }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text(entry.created.formatted(date: .abbreviated, time: .omitted) +
                         " · \(entry.completedCount)/\(entry.pages.count) 页")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            Menu {
                Button("移到废纸篓", role: .destructive) { workspace.trashHistory(entry.id) }
            } label: { Image(systemName: "ellipsis").frame(width: 17) }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("记录操作")
        }
        .disabled(workspace.isWorking)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(selected ? PaperTheme.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}
