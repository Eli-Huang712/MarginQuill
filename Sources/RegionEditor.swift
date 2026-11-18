import SwiftUI

struct RegionEditor: View {
    @ObservedObject var workspace: Workspace
    let page: PaperPage
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paperAccent) private var accent
    @AppStorage(PreferenceKey.paddleDirectory) private var runtimeDirectory = ""
    @State private var kind = RegionRecognitionKind.formula
    @State private var selection: CGRect?
    @State private var output: String?
    @State private var failure: String?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("框选局部识别")).font(.title2.weight(.semibold))
                    Text(L("在原图上拖动，框住所需的公式或折线图。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker(L("识别内容"), selection: $kind) {
                    ForEach(RegionRecognitionKind.allCases) { item in Text(item.title).tag(item) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 177)
                .disabled(running)
                .onChange(of: kind) { _, _ in
                    output = nil
                    failure = nil
                }
            }

            canvas
                .frame(minHeight: 210, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            if PaddleRuntime.configured(runtimeDirectory) == nil {
                HStack {
                    Text(L("请选择包含 Python 环境和 PaddleOCR-VL 模型的目录。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("选择模型目录…")) {
                        if let path = PaddleRuntime.chooseDirectory(runtimeDirectory) { runtimeDirectory = path }
                    }
                }
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
            }
            if output != nil {
                Text(L("核对识别结果后可编辑或加入文稿。")).font(.caption).foregroundStyle(.secondary)
                MarkdownEditor(text: Binding(get: { output ?? "" }, set: { output = $0 }), isEditable: !running)
                    .frame(height: 116)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 10) {
                if running {
                    ProgressView().progressViewStyle(.linear).frame(width: 74)
                    Text(RecognitionEngine.paddle.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(output == nil ? L("取消") : L("完成"), role: .cancel) { dismiss() }.disabled(running)
                if let output {
                    Button(L("复制 Markdown")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output, forType: .string)
                    }
                    .disabled(trimmedOutput.isEmpty || running)
                    Button(L("加入文稿")) { addOutput() }
                        .buttonStyle(.borderedProminent)
                        .disabled(trimmedOutput.isEmpty || running)
                } else {
                    Button(L("识别所选区域"), action: recognize)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(selection == nil || running || PaddleRuntime.configured(runtimeDirectory) == nil)
                }
            }
        }
        .padding(22)
        .tint(accent.color)
        .interactiveDismissDisabled(running)
    }

    @ViewBuilder
    private var canvas: some View {
        if let photo = page.originalImage {
            GeometryReader { geometry in
                let image = PaperImage.imageFrame(geometry.size, photo: photo.size)
                PaperImage(photo: photo, annotation: selection, badge: nil)
                    .overlay {
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 4)
                                .onChanged { drag in updateSelection(from: drag.startLocation, to: drag.location, image: image) }
                                .onEnded { _ in
                                    if let selection, min(selection.width * image.width, selection.height * image.height) < 8 {
                                        self.selection = nil
                                    }
                                })
                            .allowsHitTesting(!running)
                            .accessibilityLabel(L("框选识别区域"))
                    }
            }
        }
    }

    private var trimmedOutput: String { output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    private func updateSelection(from start: CGPoint, to end: CGPoint, image: CGRect) {
        guard image.contains(start) else { return }
        let x = max(image.minX, min(image.maxX, end.x))
        let y = max(image.minY, min(image.maxY, end.y))
        selection = CGRect(x: (min(start.x, x) - image.minX) / image.width,
                           y: (min(start.y, y) - image.minY) / image.height,
                           width: abs(x - start.x) / image.width, height: abs(y - start.y) / image.height)
        output = nil
        failure = nil
    }

    private func recognize() {
        guard let selection, let runtime = PaddleRuntime.configured(runtimeDirectory) else { return }
        running = true
        failure = nil
        Task {
            defer { running = false }
            do {
                output = try await workspace.recognizeRegion(page: page, region: selection, kind: kind, runtime: runtime)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func addOutput() {
        do {
            try workspace.addRegion(trimmedOutput, to: page.id)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
