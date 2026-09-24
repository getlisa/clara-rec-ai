import ImageIO
import UIKit

/// Makes a JPEG safe to put in the proposal document.
///
/// The server normalises orientation with `sharp().rotate()` — but **only for uploads that are not
/// already JPEG or PNG**. A JPEG takes the fast path and is stored byte-for-byte, tag intact. The
/// document builders then read dimensions straight from the SOF header and ignore EXIF entirely
/// (`proposalDocx.ts`: *"EXIF orientation is ignored; add a rotation pass if sideways phone photos
/// show up"*).
///
/// So a capture with orientation ≠ 1 looks right everywhere in the app and lands sideways in the
/// customer's PDF. Baking the rotation into the pixels here is the cheap half of that fix, and it
/// needs no backend change.
enum JPEGOrientation {
    /// EXIF orientation values other than 1 mean the pixels need rotating before anyone who
    /// ignores the tag can read them.
    static let upright: UInt32 = 1

    /// Reads the EXIF orientation tag, or nil when the data carries none.
    static func orientation(of jpeg: Data) -> UInt32? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let value = properties[kCGImagePropertyOrientation] as? UInt32
        else { return nil }
        return value
    }

    /// True when the tag is absent or already upright — nothing to do.
    static func isUpright(_ jpeg: Data) -> Bool {
        guard let value = orientation(of: jpeg) else { return true }
        return value == upright
    }

    /// Returns a JPEG whose pixels are already rotated and whose orientation tag is upright.
    ///
    /// Returns the input untouched when it is already upright, so the common case costs one header
    /// read and no re-encode — which matters, because re-encoding is lossy.
    static func normalized(_ jpeg: Data, quality: CGFloat = 0.9) -> Data {
        guard !isUpright(jpeg) else { return jpeg }
        guard let image = UIImage(data: jpeg) else { return jpeg }

        // Drawing applies the orientation; the result is `.up` with the rotation in the pixels.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let redrawn = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }

        return redrawn.jpegData(compressionQuality: quality) ?? jpeg
    }
}
