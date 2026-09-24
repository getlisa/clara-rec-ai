import XCTest

/// Mirrors the Android AuthorTest so both platforms write the same prefixes into the bucket.
final class AuthorTests: XCTestCase {
    func testPrefixFallsBackToIdWhenNoNameIsSet() {
        XCTAssertEqual(Author(id: "a1b2c3d4", name: "").storagePrefix, "a1b2c3d4")
        XCTAssertEqual(Author(id: "a1b2c3d4", name: "   ").storagePrefix, "a1b2c3d4")
    }

    func testPrefixKeepsTheIdSoIdenticalNamesNeverCollide() {
        XCTAssertEqual(Author(id: "a1b2c3d4", name: "Shivam").storagePrefix, "shivam-a1b2c3d4")
        XCTAssertEqual(Author(id: "99887766", name: "Shivam").storagePrefix, "shivam-99887766")
    }

    func testNamesAreSlugifiedIntoSomethingS3Safe() {
        XCTAssertEqual(Author(id: "ff00", name: "Bob  Smith").storagePrefix, "bob-smith-ff00")
        XCTAssertEqual(Author(id: "ff00", name: "  a/b  ").storagePrefix, "a-b-ff00")
        XCTAssertEqual(Author(id: "ff00", name: "José").storagePrefix, "jose-ff00")
        // A name made entirely of punctuation slugifies away, leaving the id alone.
        XCTAssertEqual(Author(id: "ff00", name: "!!!").storagePrefix, "ff00")
    }

    func testVeryLongNamesAreTruncatedWithoutATrailingSeparator() {
        let long = String(repeating: "x", count: 80)
        XCTAssertEqual(
            Author(id: "ff00", name: long).storagePrefix,
            "\(String(repeating: "x", count: 32))-ff00"
        )

        let trailing = "\(String(repeating: "y", count: 32)) tail"
        XCTAssertEqual(
            Author(id: "ff00", name: trailing).storagePrefix,
            "\(String(repeating: "y", count: 32))-ff00"
        )

        // Truncating right after a separator must not leave "name--id".
        let cutAtSeparator = "\(String(repeating: "z", count: 31)) tail"
        XCTAssertEqual(
            Author(id: "ff00", name: cutAtSeparator).storagePrefix,
            "\(String(repeating: "z", count: 31))-ff00"
        )
    }
}
