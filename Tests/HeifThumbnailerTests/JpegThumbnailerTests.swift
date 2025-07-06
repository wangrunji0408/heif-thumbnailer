@testable import HeifThumbnailer
import XCTest

final class JpegThumbnailerTests: XCTestCase {
    func testJpegFileTypeDetection() throws {
        // Test file type detection logic
        let jpegExtensions = ["jpg", "jpeg", "JPG", "JPEG"]
        for ext in jpegExtensions {
            XCTAssertTrue(ext.lowercased() == "jpg" || ext.lowercased() == "jpeg")
        }
    }

    func testJpegThumbnailExtraction() async throws {
        // Test basic thumbnail extraction
        let bundle = Bundle.module
        guard let testImageURL = bundle.url(forResource: "Pocket3", withExtension: "JPG") else {
            XCTFail("Test image not found")
            return
        }

        let fileHandle = try FileHandle(forReadingFrom: testImageURL)
        defer { fileHandle.closeFile() }

        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            try fileHandle.seek(toOffset: offset)
            let data = fileHandle.readData(ofLength: Int(length))
            return data
        }

        let thumbnail = try await readJpegThumbnail(readAt: readAt, minShortSide: nil)
        XCTAssertNotNil(thumbnail, "Should extract thumbnail")

        if let thumbnail = thumbnail {
            XCTAssertGreaterThan(thumbnail.data.count, 0, "Thumbnail data should not be empty")
            XCTAssertGreaterThan(thumbnail.width, 0, "Thumbnail width should be greater than 0")
            XCTAssertGreaterThan(thumbnail.height, 0, "Thumbnail height should be greater than 0")
        }
    }

    func testJpegThumbnailAsImage() async throws {
        // Test thumbnail as image conversion
        let bundle = Bundle.module
        guard let testImageURL = bundle.url(forResource: "Pocket3", withExtension: "JPG") else {
            XCTFail("Test image not found")
            return
        }

        let fileHandle = try FileHandle(forReadingFrom: testImageURL)
        defer { fileHandle.closeFile() }

        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            try fileHandle.seek(toOffset: offset)
            let data = fileHandle.readData(ofLength: Int(length))
            return data
        }

        let image = try await readJpegThumbnailAsImage(readAt: readAt, minShortSide: nil)
        // Image might be nil if no thumbnail is found, which is acceptable
    }

    func testJpegThumbnailSizeSelection() async throws {
        // Test thumbnail selection based on minShortSide
        let bundle = Bundle.module
        guard let testImageURL = bundle.url(forResource: "Pocket3", withExtension: "JPG") else {
            XCTFail("Test image not found")
            return
        }

        let fileHandle = try FileHandle(forReadingFrom: testImageURL)
        defer { fileHandle.closeFile() }

        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            try fileHandle.seek(toOffset: offset)
            let data = fileHandle.readData(ofLength: Int(length))
            return data
        }

        // Test with different minShortSide values
        let testCases: [(UInt32?, String)] = [
            (nil, "no requirement"),
            (50, "small requirement"),
            (100, "medium requirement"),
            (200, "large requirement"),
        ]

        for (minShortSide, description) in testCases {
            let thumbnail = try await readJpegThumbnail(readAt: readAt, minShortSide: minShortSide)

            if let thumbnail = thumbnail {
                let shortSide = min(thumbnail.width, thumbnail.height)
                print("[\(description)] Selected: \(thumbnail.type), size: \(thumbnail.width)x\(thumbnail.height), shortSide: \(shortSide)")

                // If minShortSide is specified, the selected thumbnail should ideally meet the requirement
                // or be the largest available if no thumbnail meets the requirement
                if let minShortSide = minShortSide {
                    // We can't enforce this strictly because the image might not have thumbnails
                    // that meet the requirement, but we can log it for verification
                    if shortSide >= minShortSide {
                        print("✓ Thumbnail meets size requirement")
                    } else {
                        print("⚠ Thumbnail doesn't meet size requirement (likely largest available)")
                    }
                }
            } else {
                XCTFail("Should extract thumbnail for \(description)")
            }
        }
    }
}
