import SwiftUI

struct PaperImage: View {
    @Environment(\.paperAccent) private var accent
    let photo: NSImage
    let annotation: CGRect?
    let badge: String?

    var body: some View {
        GeometryReader { geometry in
            let available = CGSize(width: max(1, geometry.size.width - 30),
                                   height: max(1, geometry.size.height - 30))
            let scale = min(available.width / photo.size.width, available.height / photo.size.height)
            let image = CGRect(
                x: (geometry.size.width - photo.size.width * scale) / 2,
                y: (geometry.size.height - photo.size.height * scale) / 2,
                width: photo.size.width * scale, height: photo.size.height * scale
            )
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
