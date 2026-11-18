import AppKit
import SwiftUI

enum PaperTheme {
    static let divider = Color(nsColor: .separatorColor).opacity(0.62)
    static let surface = Color(nsColor: .windowBackgroundColor)
}

private enum SidebarSection {
    case review, todos, events
}

struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace
    var capture: CaptureButton
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PreferenceKey.appearance) private var appearance = AppAppearance.system
    @AppStorage(PreferenceKey.accent) private var accent = AppAccent.purple
    @AppStorage(PreferenceKey.tokenUsage) private var showsTokenUsage = true
    @AppStorage("showsReviewSidebar") private var showingReview = true
    @State private var sidebarSection = SidebarSection.review
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
        .tint(accent.color)
        .environment(\.paperAccent, accent)
        .environment(\.locale, InterfaceLanguage.locale)
        .onChange(of: appearance, initial: true) { _, value in value.apply() }
        .sheet(isPresented: $workspace.showingSettings) { SettingsView(workspace: workspace) }
        .onChange(of: workspace.record?.id) { _, _ in
            clearFocus()
            showingResolved = false
            sidebarSection = .review
        }
        .onChange(of: workspace.selectedPageID) { _, selected in
            inspectOriginal = false
            if focus?.page != selected { clearFocus() }
        }
    }

    private var workArea: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let historyDocked = width >= 1200
            let reviewDocked = width >= 1010
            let paperWidth = min(350, max(240, width * 0.27))
            let reviewWidth = min(302, max(266, width * 0.235))
            HStack(spacing: 0) {
                Color.clear.frame(width: historyDocked && workspace.showingHistory ? 213 : 0)
                    .accessibilityHidden(true)
                HSplitView {
                    sourcePane
                        .frame(minWidth: 230, idealWidth: paperWidth, maxWidth: paperWidth, maxHeight: .infinity)
                        .layoutPriority(1)
                    documentPane
                        .frame(minWidth: 338, maxWidth: .infinity, maxHeight: .infinity)
                }
                Color.clear.frame(width: reviewDocked && showingReview ? reviewWidth : 0)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .leading) {
                slidingSidebar(width: 213, visible: workspace.showingHistory, edge: .leading) {
                    historyPane(docked: historyDocked)
                }
                .shadow(color: .black.opacity(!historyDocked && workspace.showingHistory ? 0.16 : 0), radius: 10, x: 4)
            }
            .overlay(alignment: .trailing) {
                slidingSidebar(width: reviewWidth, visible: showingReview, edge: .trailing) {
                    reviewPane
                }
                .shadow(color: .black.opacity(!reviewDocked && showingReview ? 0.16 : 0), radius: 10, x: -4)
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: workspace.showingHistory)
            .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: showingReview)
            .sheet(item: $cropPage) { page in
                CropEditor(workspace: workspace, page: page)
                    .frame(width: min(900, width - 48), height: min(710, max(395, geometry.size.height - 38)))
            }
        }
    }

    private func slidingSidebar<Content: View>(width: CGFloat, visible: Bool, edge: HorizontalEdge,
                                               @ViewBuilder content: () -> Content) -> some View {
        let alignment: Alignment = edge == .leading ? .trailing : .leading
        return content()
            .frame(width: width)
            .overlay(alignment: alignment) { Rectangle().fill(PaperTheme.divider).frame(width: 1) }
            .frame(width: visible ? width : 0, alignment: alignment)
            .clipped()
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
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
                Text(L("纸稿")).font(.headline)
                if !workspace.pages.isEmpty {
                    Text(L("%@ 页", workspace.pages.count))
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
                        Text(pageImageLabel(page))
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

    private func pageImageLabel(_ page: PaperPage) -> String {
        if inspectOriginal { return L("原图") }
        if page.trimBounds != nil { return L("已裁外围留白") }
        return page.appliedCorners == nil ? L("完整画面") : L("裁正后")
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
                    .strokeBorder(selected ? accent.color : PaperTheme.divider, lineWidth: selected ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("第 %@ 页，%@", index + 1, page.source.name))
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
                pageAction("arrow.left", label: L("前移选中页")) { workspace.movePage(page.id, by: -1) }
                    .disabled(index == 0 || workspace.isWorking)
                pageAction("arrow.right", label: L("后移选中页")) { workspace.movePage(page.id, by: 1) }
                    .disabled(index + 1 == workspace.pages.count || workspace.isWorking)
                pageAction("minus", label: L("移除选中页")) { workspace.removePage(page.id) }
                    .disabled(workspace.isWorking)
                Spacer(minLength: 5)
                ViewThatFits(in: .horizontal) {
                    Button { cropPage = page } label: { Label(L("调整角点"), systemImage: "crop") }
                        .fixedSize()
                    Button { cropPage = page } label: { Image(systemName: "crop") }
                }
                .help(L("调整角点"))
                .accessibilityLabel(L("调整角点"))
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
                    annotation: inspectOriginal || focusedPhoto == nil ? nil : focusedBox?.visibleRect,
                    badge: focus.flatMap { selection in
                        annotationNumbers[selection.annotation].map {
                            let kind: AnnotationKind = events.contains { $0.id == selection.annotation } ? .event :
                                (todos.contains { $0.id == selection.annotation } ? .todo : .review)
                            return L("%@ %@", kind.title, $0)
                        }
                    }
                )
                if selected.preparedImage != nil {
                    Button(inspectOriginal ? L("查看处理后") : L("查看原图")) { inspectOriginal.toggle() }
                    .controlSize(.small)
                    .padding(8)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 37, weight: .light)).foregroundStyle(accent.color)
                        .accessibilityHidden(true)
                    Text(L("拖入纸稿")).font(.subheadline.weight(.medium))
                    Text(L("支持多张照片和多页 PDF"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L("用 iPhone 连扫多页时，选择「扫描文稿」。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minHeight: 145, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(dropTargeted ? accent.color : PaperTheme.divider,
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
                Text(L("识别模型")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker(L("识别模型"), selection: $workspace.model) {
                    ForEach(RecognitionModel.allCases) { model in Text(model.label).tag(model) }
                }
                .labelsHidden().frame(width: 133).disabled(workspace.isRecognizing)
            }
            if workspace.isRecognizing {
                Button(action: workspace.cancelRecognition) {
                    Label(L("停止识别"), systemImage: "stop.circle").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            } else {
                Button(action: workspace.recognize) {
                    Label(recognizeLabel, systemImage: "text.viewfinder").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(workspace.pages.isEmpty || workspace.isPreparing)
                .help(L("按左上方的页序识别纸稿"))
            }
        }
    }

    private var recognizeLabel: String {
        if let record = workspace.record, workspace.canResume,
           record.model == workspace.model, record.completedCount > 0 {
            return L("继续识别 %@ 页", record.pages.count - record.completedCount)
        }
        if workspace.pages.isEmpty { return L("识别纸稿") }
        return L("识别 %@ 页", workspace.pages.count)
    }

    private var documentPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L("文档")).font(.headline).fixedSize()
                Spacer(minLength: 4)
                ViewThatFits(in: .horizontal) {
                    documentActions(compact: false).fixedSize(horizontal: true, vertical: false)
                    documentActions(compact: true)
                }
            }
            .padding(.horizontal, 15)
            .frame(height: 47)
            Divider()
            ZStack {
                Color(nsColor: .textBackgroundColor)
                if workspace.showingSource {
                    MarkdownEditor(text: Binding(get: { workspace.markdown }, set: { workspace.editMarkdown($0) }),
                                   isEditable: !workspace.isRecognizing)
                } else if !workspace.markdown.isEmpty {
                    MarkdownPreview(sections: previewSections, annotations: previewAnnotations,
                                    focus: focus, openAnnotation: openAnnotation)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 39, weight: .ultraLight))
                            .foregroundStyle(accent.color)
                            .accessibilityHidden(true)
                        Text(L("文档预览")).font(.headline)
                        Text(workspace.record != nil && !workspace.isRecognizing && !workspace.canResume
                             ? L("可在源码中补录正文。") : L("识别后在这里阅读正文和框图。"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func documentActions(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            if workspace.record != nil {
                let title = workspace.showingSource ? L("显示预览") : L("还原源码")
                Button {
                    workspace.showingSource.toggle()
                } label: {
                    actionLabel(title, icon: workspace.showingSource ? "doc.richtext" :
                                    "chevron.left.forwardslash.chevron.right", compact: compact)
                }
                .help(title).accessibilityLabel(title)
                .disabled(workspace.isRecognizing)
            }
            Button(action: workspace.copy) { Image(systemName: "document.on.document") }
                .help(L("复制 Markdown")).accessibilityLabel(L("复制 Markdown"))
                .disabled(workspace.markdown.isEmpty)
            Button(action: workspace.export) { actionLabel(L("导出…"), icon: "square.and.arrow.up", compact: compact) }
                .help(L("导出 Markdown")).accessibilityLabel(L("导出 Markdown"))
                .disabled(workspace.markdown.isEmpty)
            if !showingReview {
                Button { showingReview = true } label: {
                    HStack(spacing: 5) {
                        actionLabel(sidebarTitle, icon: "sidebar.right", compact: compact)
                        countBadge(reviewCount + todoCount + eventCount)
                    }
                }
                .help(L("展开%@侧栏", sidebarTitle))
                .accessibilityLabel(L("展开%@侧栏", sidebarTitle))
                .accessibilityValue(L("%@ 项待核对，%@ 项待办，%@ 项日历", reviewCount, todoCount, eventCount))
            }
        }
    }

    @ViewBuilder
    private func actionLabel(_ title: String, icon: String, compact: Bool) -> some View {
        if compact { Image(systemName: icon) } else { Label(title, systemImage: icon) }
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

    private var todos: [PaperTodo] { workspace.record?.pages.flatMap { $0.todos ?? [] } ?? [] }
    private var todoCount: Int { todos.filter { $0.delivery?.sent != true }.count }
    private var events: [PaperEvent] { workspace.record?.pages.flatMap { $0.events ?? [] } ?? [] }
    private var eventCount: Int { events.filter { $0.delivery?.sent != true }.count }
    private var hasActions: Bool { !todos.isEmpty || !events.isEmpty }
    private var sidebarTitle: String { hasActions ? L("批注") : L("待核对") }

    @ViewBuilder
    private func countBadge(_ count: Int) -> some View {
        if count > 0 {
            Text("\(count)").font(.caption.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(accent.color.opacity(0.13), in: Capsule())
                .foregroundStyle(accent.color)
        }
    }

    private var annotationNumbers: [UUID: Int] {
        let issues = workspace.record?.pages.flatMap(\.issues).map(\.id) ?? []
        let tasks = todos.map(\.id)
        return Dictionary(uniqueKeysWithValues: [issues, tasks, events.map(\.id)].flatMap { ids in
            ids.enumerated().map { ($0.element, $0.offset + 1) }
        })
    }

    private var focusedBox: ReviewBox? {
        guard let focus, let page = workspace.record?.pages.first(where: { $0.id == focus.page }) else { return nil }
        return page.issues.first { $0.id == focus.annotation }?.box
            ?? page.todos?.first { $0.id == focus.annotation }?.box
            ?? page.events?.first { $0.id == focus.annotation }?.box
    }

    private var previewAnnotations: [PreviewAnnotation] {
        guard let record = workspace.record else { return [] }
        let numbers = annotationNumbers
        return record.pages.flatMap { page in
            let section = record.editedMarkdown == nil ? page.id.uuidString : "document"
            let issues = page.issues.filter { !$0.resolved }.compactMap { item in
                numbers[item.id].map { number in
                    PreviewAnnotation(id: item.id, section: section, number: number,
                                      category: item.category, anchor: item.anchor)
                }
            }
            let tasks = (page.todos ?? []).compactMap { todo in
                numbers[todo.id].map { number in
                    PreviewAnnotation(id: todo.id, section: section, number: number,
                                      category: todo.delivery?.title ?? todo.title, anchor: todo.anchor, kind: .todo)
                }
            }
            let appointments = (page.events ?? []).compactMap { event in
                numbers[event.id].map { number in
                    PreviewAnnotation(id: event.id, section: section, number: number,
                                      category: event.delivery?.title ?? event.title, anchor: event.anchor, kind: .event)
                }
            }
            return issues + tasks + appointments
        }
    }

    private func openAnnotation(_ id: UUID) {
        guard let page = workspace.record?.pages.first(where: {
            $0.issues.contains { $0.id == id } || $0.todos?.contains { $0.id == id } == true ||
                $0.events?.contains { $0.id == id } == true
        }) else { return }
        workspace.showIssuePage(page.id)
        inspectOriginal = false
        focusedPhoto = workspace.recognizedImage(for: page.id)
        if page.events?.contains(where: { $0.id == id }) == true {
            sidebarSection = .events
        } else {
            sidebarSection = page.todos?.contains { $0.id == id } == true ? .todos : .review
        }
        focus = PreviewFocus(page: page.id, annotation: id)
        showingReview = true
    }

    private func clearFocus() {
        focus = nil
        focusedPhoto = nil
    }

    private var reviewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "checklist").foregroundStyle(accent.color).accessibilityHidden(true)
                Text(sidebarTitle).font(.headline)
                if !hasActions { countBadge(reviewCount) }
                Spacer()
                Button { showingReview = false } label: { Image(systemName: "sidebar.right") }
                    .help(L("收起%@侧栏", sidebarTitle))
                    .accessibilityLabel(L("收起%@侧栏", sidebarTitle))
            }
            .padding(.horizontal, 15).frame(height: 47)
            Divider()
            if hasActions {
                Picker(L("批注类别"), selection: $sidebarSection) {
                    Text(L("待核对 %@", reviewCount)).tag(SidebarSection.review)
                    if !todos.isEmpty { Text(L("待办 %@", todoCount)).tag(SidebarSection.todos) }
                    if !events.isEmpty { Text(L("日历 %@", eventCount)).tag(SidebarSection.events) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            if let record = workspace.record {
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if sidebarSection == .events {
                                ForEach(Array(record.pages.enumerated()), id: \.element.id) { index, page in
                                    ForEach(page.events ?? []) { event in
                                        CalendarCard(workspace: workspace, event: event,
                                                     number: annotationNumbers[event.id] ?? 0, page: index + 1,
                                                     selected: focus?.annotation == event.id) {
                                            openAnnotation(event.id)
                                        }
                                        .id(event.id)
                                    }
                                }
                            } else if sidebarSection == .todos {
                                ForEach(Array(record.pages.enumerated()), id: \.element.id) { index, page in
                                    ForEach(page.todos ?? []) { todo in
                                        ReminderCard(workspace: workspace, todo: todo,
                                                     number: annotationNumbers[todo.id] ?? 0, page: index + 1,
                                                     selected: focus?.annotation == todo.id) {
                                            openAnnotation(todo.id)
                                        }
                                        .id(todo.id)
                                    }
                                }
                            } else {
                                reviewItems(record)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    }
                    .onChange(of: focus, initial: true) { _, selected in
                        if let selected { scroll.scrollTo(selected.annotation, anchor: .center) }
                    }
                }
            } else {
                Text(L("点开疑点，即可查看对应的纸稿。"))
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(15)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(PaperTheme.surface)
    }

    @ViewBuilder
    private func reviewItems(_ record: NoteRecord) -> some View {
        let resolved = record.pages.flatMap(\.issues).contains { $0.resolved }
        if resolved {
            Toggle(L("显示已处理"), isOn: $showingResolved)
                .toggleStyle(.checkbox).font(.caption)
        }
        ForEach(Array(record.pages.enumerated()), id: \.element.id) { index, page in
            if let error = page.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("第 %@ 页 · 识别暂停", index + 1)).font(.subheadline.weight(.semibold))
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(accent.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            }
            ForEach(page.issues.filter { showingResolved || !$0.resolved }) { item in
                issueCard(item, page: page, index: index).id(item.id)
            }
        }
        if reviewCount == 0 && !record.pages.contains(where: { $0.error != nil }) &&
            !(resolved && showingResolved) {
            Text(workspace.isRecognizing ? L("等待识别结果…") :
                    (record.completedCount == 0 ? L("识别后的疑点会显示在这里。") : L("已完成页面没有待核对项。")))
                .font(.callout).foregroundStyle(.secondary)
                .padding(.top, 3)
        }
    }

    private func issueCard(_ item: ReviewItem, page: NoteRecord.Page, index: Int) -> some View {
        let selected = focus?.annotation == item.id
        let number = annotationNumbers[item.id] ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                openAnnotation(item.id)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("\(number)")
                            .font(.caption.weight(.semibold)).monospacedDigit()
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(accent.color.opacity(0.13), in: Capsule())
                        Text(L("第 %@ 页 · %@", index + 1, item.category))
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(accent.color)
                    if !item.location.isEmpty {
                        Text(item.location).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(item.detail).font(.callout).foregroundStyle(.primary)
                    if selected, item.box?.visibleRect != nil, focusedPhoto != nil, !inspectOriginal {
                        Text(L("已标出原稿大致位置")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("定位到第 %@ 张纸稿", index + 1))
            Button {
                workspace.markIssue(item.id, page: page.id, resolved: !item.resolved)
                if selected && !item.resolved { clearFocus() }
            } label: {
                Label(item.resolved ? L("恢复待核对") : L("标为已处理"),
                      systemImage: item.resolved ? "arrow.uturn.backward" : "checkmark")
            }
            .buttonStyle(ReviewActionButtonStyle())
            .disabled(workspace.isRecognizing)
        }
        .padding(10)
        .background(selected ? accent.color.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selected ? accent.color.opacity(0.70) : PaperTheme.divider)
                .allowsHitTesting(false)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if workspace.isWorking { ProgressView().controlSize(.small) }
            if let error = workspace.error {
                Label(error, systemImage: "exclamationmark.circle").lineLimit(1)
            } else if workspace.imagesChanged, workspace.record != nil, !workspace.isWorking {
                Text(L("纸稿已调整，下次识别会建立新记录。")).lineLimit(1)
            } else {
                Text(workspace.notice).lineLimit(1)
            }
            Spacer()
            if showsTokenUsage, let usage = workspace.record?.usage, let input = usage.inputTokens,
               let output = usage.outputTokens {
                let total = L("共 %@ tokens", (input + output).formatted())
                let breakdown = L("输入 %@ · 输出 %@ tokens", input.formatted(), output.formatted())
                Text(total)
                    .monospacedDigit()
                    .help(breakdown)
                    .accessibilityLabel(total + " · " + breakdown)
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
        @Environment(\.paperAccent) private var accent
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 6)
            let fill = configuration.isPressed ? 0.27 : (isHovered ? 0.18 : 0.075)
            let outline = configuration.isPressed || isHovered ? 0.58 : 0.23
            configuration.label
                .font(.caption.weight(.medium))
                .foregroundStyle(isEnabled ? accent.color : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(accent.color.opacity(isEnabled ? fill : 0.045), in: shape)
                .overlay {
                    shape.strokeBorder(accent.color.opacity(isEnabled ? outline : 0.12))
                        .allowsHitTesting(false)
                }
                .contentShape(shape)
                .onHover { isHovered = $0 }
        }
    }
}

struct HistorySidebar: View {
    @Environment(\.paperAccent) private var accent
    @ObservedObject var workspace: Workspace
    var afterOpening: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("历史记录"))
                .font(.headline)
                .padding(.horizontal, 14)
                .frame(height: 47, alignment: .leading)
            Divider()
            if workspace.history.isEmpty {
                Text(L("还没有记录")).font(.callout).foregroundStyle(.secondary).padding(14)
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
                         L(" · %@/%@ 页", entry.completedCount, entry.pages.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            Menu {
                Button(L("移到废纸篓"), role: .destructive) { workspace.trashHistory(entry.id) }
            } label: { Image(systemName: "ellipsis").frame(width: 17) }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L("记录操作"))
        }
        .disabled(workspace.isWorking)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(selected ? accent.color.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}
