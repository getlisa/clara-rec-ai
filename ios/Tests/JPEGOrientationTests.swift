import ImageIO
import UIKit
import XCTest

/// The server only normalises orientation for uploads that are *not* already JPEG or PNG, and the
/// proposal builders then ignore the EXIF tag entirely. A glasses JPEG tagged anything but 1 would
/// print sideways in the customer's PDF while looking correct in the app — so the rotation has to
/// happen here, before upload.
final class JPEGOrientationTests: XCTestCase {
    /// 40×20 pixels, tagged with the given EXIF orientation.
    private func makeJPEG(orientation: UInt32) throws -> Data {
        let size = CGSize(width: 40, height: 20)
        // Pin the scale: the renderer defaults to the simulator's 3×, which would make the
        // fixture 120×60 pixels and the pixel-dimension assertions below meaningless.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let cgImage = try XCTUnwrap(drawn.cgImage)

        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(
            destination, cgImage,
            [kCGImagePropertyOrientation: orientation] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func testReadsTheOrientationTag() throws {
        XCTAssertEqual(JPEGOrientation.orientation(of: try makeJPEG(orientation: 6)), 6)
        XCTAssertEqual(JPEGOrientation.orientation(of: try makeJPEG(orientation: 1)), 1)
    }

    func testAnUprightPhotoIsReturnedByteForByte() throws {
        // Re-encoding is lossy, so the common case must not touch the pixels.
        let upright = try makeJPEG(orientation: 1)
        XCTAssertTrue(JPEGOrientation.isUpright(upright))
        XCTAssertEqual(JPEGOrientation.normalized(upright), upright)
    }

    /// Orientation 6 means "rotate 90° CW to display", so a 40×20 stored image displays as 20×40.
    /// After normalising, those must be the actual pixel dimensions — that is what the proposal
    /// builder reads straight out of the SOF header.
    func testRotationIsBakedIntoThePixels() throws {
        let sideways = try makeJPEG(orientation: 6)
        XCTAssertFalse(JPEGOrientation.isUpright(sideways))

        let normalized = JPEGOrientation.normalized(sideways)
        let image = try XCTUnwrap(UIImage(data: normalized))

        XCTAssertEqual(image.imageOrientation, .up)
        XCTAssertEqual(image.cgImage?.width, 20)
        XCTAssertEqual(image.cgImage?.height, 40)

        let tag = JPEGOrientation.orientation(of: normalized)
        XCTAssertTrue(tag == nil || tag == JPEGOrientation.upright,
                      "normalised data must not still claim a rotation, got \(String(describing: tag))")
    }

    /// Every rotating orientation has to produce upright pixels, not just the common one.
    func testEveryRotatedOrientationEndsUpright() throws {
        for orientation in UInt32(2)...UInt32(8) {
            let data = try makeJPEG(orientation: orientation)
            let normalized = JPEGOrientation.normalized(data)
            let image = try XCTUnwrap(UIImage(data: normalized), "orientation \(orientation)")
            XCTAssertEqual(image.imageOrientation, .up, "orientation \(orientation)")
        }
    }

    /// Data that isn't an image must come back untouched rather than crashing the capture flow.
    func testNonImageDataPassesThrough() {
        let junk = Data("not an image".utf8)
        XCTAssertEqual(JPEGOrientation.normalized(junk), junk)
        XCTAssertTrue(JPEGOrientation.isUpright(junk))
    }
}
