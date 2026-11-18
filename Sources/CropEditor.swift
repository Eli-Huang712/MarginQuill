import SwiftUI

struct CropEditor: View {
    @ObservedObject var workspace: Workspace
    let page: PaperPage
    @Environment(\.dismiss) private var dismiss
    @State private var corners: [PagePoint]
    @State private var enhanced: Bool
    @State private var error: String?

    init(workspace: Workspace, page: PaperPage) {
        self.workspace = workspace
        self.page = page
        _corners = State(initialValue: page.appliedCorners ?? page.automaticCorners ?? page.cornerSuggestions.first ?? .fullPageInset)
        _enhanced = State(initialValue: page.enhanced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("调整纸页角点").font(.title2.weight(.semibold))
                    Text("拖动四角，让边线贴合纸张。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if !candidates.isEmpty {
                    Menu("纸边候选") {
                        ForEach(candidates.indices, id: \.self) { index in
                            Button("候选 \(index + 1)") { corners = candidates[index] }
                        }
                    }
                    .disabled(workspace.isPreparing)
                }
                Button(action: redetect) {
                    Label("重新检测", systemImage: "arrow.clockwise")
                }.disabled(workspace.isPreparing)
            }
            canvas
                .frame(minHeight: 225, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Toggle("轻增强", isOn: $enhanced).toggleStyle(.checkbox)
                    .disabled(workspace.isPreparing)
                Button("使用整张") { apply(.entirePage) }.disabled(workspace.isPreparing)
                Spacer()
                if workspace.isPreparing { ProgressView().controlSize(.small) }
                Button("取消", role: .cancel) { dismiss() }.disabled(workspace.isPreparing)
                Button("应用裁切") { apply(.manual(corners)) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(workspace.isPreparing)
            }
        }
        .padding(22)
        .tint(PaperTheme.accent)
        .interactiveDismissDisabled(workspace.isPreparing)
    }

    private var canvas: some View {
        GeometryReader { geometry in
            if let source = page.originalImage {
                let available = CGSize(width: max(1, geometry.size.width - 44), height: max(1, geometry.size.height - 44))
                let scale = min(available.width / source.size.width, available.height / source.size.height)
                let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
                let image = CGRect(x: (geometry.size.width - size.width) / 2,
                                   y: (geometry.size.height - size.height) / 2,
                                   width: size.width, height: size.height)
                let screenPoints = corners.map { CGPoint(x: image.minX + $0.x * image.width,
                                                         y: image.minY + $0.y * image.height) }
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    Image(nsImage: source)
                        .resizable().frame(width: size.width, height: size.height)
                        .position(x: image.midX, y: image.midY)
                    Path { path in
                        path.addRect(image)
                        path.addLines(screenPoints)
                        path.closeSubpath()
                    }
                    .fill(.black.opacity(0.40), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                    Path { path in
                        path.addLines(screenPoints)
                        path.closeSubpath()
                    }
                    .stroke(PaperTheme.accent, lineWidth: 2)
                    .allowsHitTesting(false)

                    ForEach(corners.indices, id: \.self) { index in
                        Circle()
                            .fill(PaperTheme.accent)
                            .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                            .frame(width: 18, height: 18)
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                            .position(screenPoints[index])
                            .shadow(color: .black.opacity(0.20), radius: 3)
                            .accessibilityLabel(["左上角", "右上角", "右下角", "左下角"][index])
                            .accessibilityValue("\(Int(corners[index].x * 100))%, \(Int(corners[index].y * 100))%")
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("cropCanvas"))
                                .onChanged { value in
                                    guard !workspace.isPreparing else { return }
                                    corners[index] = PagePoint(
                                        x: clamped((value.location.x - image.minX) / image.width),
                                        y: clamped((value.location.y - image.minY) / image.height))
                                })
                    }
                }
                .coordinateSpace(name: "cropCanvas")
            }
        }
    }

    private func clamped(_ number: Double) -> Double { min(1, max(0, number)) }

    private var candidates: [[PagePoint]] {
        let current = workspace.pages.first { $0.id == page.id } ?? page
        if !current.cornerSuggestions.isEmpty { return current.cornerSuggestions }
        return current.automaticCorners.map { [$0] } ?? []
    }

    private func redetect() {
        error = nil
        Task {
            if await workspace.detectCorners(for: page.id) {
                if let candidate = candidates.first { corners = candidate }
            } else {
                error = workspace.error
            }
        }
    }

    private func apply(_ crop: PhotoPreprocessor.Crop) {
        error = nil
        Task {
            if await workspace.processPage(page.id, crop: crop, enhance: enhanced) {
                dismiss()
            } else {
                error = workspace.error
            }
        }
    }
}

private extension Array where Element == PagePoint {
    static var fullPageInset: Self {
        PagePoint.fullPage.map { PagePoint(x: 0.035 + $0.x * 0.93, y: 0.035 + $0.y * 0.93) }
    }
}
