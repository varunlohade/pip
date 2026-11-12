import UIKit

/// The small JPEG a chat shows for a shared drawing's link. WhatsApp drops previews over about 300 KB,
/// so it is made on the phone: at least 600 px wide, on white, and no bigger than `maxBytes`.
enum LinkPreview {
    static let maxBytes = 300 * 1024
    static let minWidth: CGFloat = 600
    static let maxWidth: CGFloat = 1200

    /// Nil when the PNG cannot be read.
    static func jpeg(_ png: Data) -> Data? {
        guard let image = UIImage(data: png), let cg = image.cgImage, cg.width > 0, cg.height > 0 else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        var width = min(max(w, minWidth), maxWidth)
        while true {
            // Very tall drawings stay within the server's 4096 px side limit.
            let size = CGSize(width: width, height: min((h * width / w).rounded(), 4096))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let flat = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            for quality in [0.8, 0.65, 0.5, 0.35] {
                if let data = flat.jpegData(compressionQuality: quality), data.count <= maxBytes { return data }
            }
            if width <= minWidth { return nil }
            width = max(minWidth, (width * 0.8).rounded())
        }
    }
}
