import SwiftUI

struct PaperImage: View {
    @Environment(\.paperAccent) private var accent
    let photo: NSImage
    let annotation: CGRect?
    let badge: String?

    static func imageFrame(_ viewport: CGSize, photo: CGSize) -> CGRect {
        let scale = min(max(1, viewport.width - 30) / photo.width,
                        max(1, viewport.height - 30) / photo.height)
        let size = CGSize(width: photo.width * scale, height: photo.height * scale)
        return CGRect(x: (viewport.width - size.width) / 2, y: (viewport.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    var body: some View {
        GeometryReader { geometry in
            let image = Self.imageFrame(geometry.size, photo: photo.size)
            Image(nsImage: photo)
                .resizable()
                .frame(width: image.width, height: image.height)
                .shadow(color: .black.opacity(0.12), radius: 7, y: 3)
                .position(x: image.midX, y: image.midY)
                .accessibilityLabel(L("纸稿预览"))

            if let annotation {
                let region = CGRect(
                    x: image.minX + annotation.minX * image.width,
                    y: image.minY + annotation.minY * image.height,
                    width: annotation.width * image.width,
                    height: annotation.height * image.height
                )
                RoundedRectangle(cornerRadius: 3)
                    .fill(accent.color.opacity(0.13))
                    .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(accent.color, lineWidth: 2) }
                    .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.30), lineWidth: 0.5) }
                    .frame(width: region.width, height: region.height)
                    .position(x: region.midX, y: region.midY)
                    .allowsHitTesting(false)
                    .accessibilityLabel(L("原稿上的大致注释位置"))

                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(nsColor: .textBackgroundColor))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(accent.color, in: Capsule())
                        .fixedSize()
                        .position(x: min(image.maxX - 26, max(image.minX + 26, region.minX + 22)),
                                  y: max(10, region.minY - 12))
                        .allowsHitTesting(false)
                }
            }
        }
    }
}
