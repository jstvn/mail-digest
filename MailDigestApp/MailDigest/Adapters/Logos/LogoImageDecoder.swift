import AppKit
import ImageIO
import MailDigestCore

/// Turns logo bytes into an image, or nil when they don't decode. SVG goes through the system renderer
/// (`NSImage(data:)`, CoreSVG on macOS 15), which never makes a network request. Anything that fails to
/// decode is treated as a failed logo, so the avatar falls back to initials.
enum LogoImageDecoder {
    /// Pixel limit for PNG icons; larger images are refused rather than decoded.
    static let maxPixelSide = 4096

    static func isValid(_ logo: SenderLogo) -> Bool { image(for: logo) != nil }

    static func image(for logo: SenderLogo) -> NSImage? {
        switch logo.format {
        case .svg:
            guard SVGSafety.isSafe(logo.data), let image = NSImage(data: logo.data),
                  image.size.width > 0, image.size.height > 0, !image.representations.isEmpty else { return nil }
            return image
        case .png:
            guard logo.data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
                  let source = CGImageSourceCreateWithData(logo.data as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
                  (1...maxPixelSide).contains(w), (1...maxPixelSide).contains(h),
                  let image = NSImage(data: logo.data), image.size.width > 0 else { return nil }
            return image
        }
    }
}
