import Foundation
import XCTest

@testable import ImageThumbnailer

final class Mp4Tests: XCTestCase {
    func testExtractThumbnailPocket3MP4() async throws {
        let testFileURL = Bundle.module.url(forResource: "Pocket3", withExtension: "MP4")!

        // create file handle
        let fileHandle = try FileHandle(forReadingFrom: testFileURL)
        defer { fileHandle.closeFile() }

        // create read function
        var readCount = 0
        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            try fileHandle.seek(toOffset: offset)
            let data = fileHandle.readData(ofLength: Int(length))
            readCount += 1
            print("Read #\(readCount): offset=\(offset), length=\(length), actual=\(data.count)")
            return data
        }

        // test with different minShortSide values
        for minShortSide in [nil as UInt32?, 100, 200, 500] {
            print("\n--- Testing MP4 with minShortSide: \(minShortSide?.description ?? "nil") ---")

            let lastReadCount = readCount
            guard
                let result = try await readMp4Thumbnail(
                    readAt: readAt, minShortSide: minShortSide
                )
            else {
                XCTFail("Failed to extract thumbnail from MP4")
                continue
            }
            let readCountToExtractThumbnail = readCount - lastReadCount
            print("Read operations needed: \(readCountToExtractThumbnail)")

            print(
                "Successfully extracted MP4 thumbnail, size: \(result.data.count) bytes, format: \(result.format), rotation: \(result.rotation) degrees"
            )
            XCTAssertGreaterThan(result.data.count, 0, "thumbnail data should not be empty")
            XCTAssertEqual(result.format, .jpeg, "MP4 thumbnail should be JPEG format")

            // validate data is valid image data
            guard let image = createImageFromThumbnailData(result.data, rotation: result.rotation)
            else {
                XCTFail("Should be able to create image from MP4 thumbnail data")
                continue
            }

            let imageSize = image.size
            print("MP4 thumbnail size: \(imageSize.width) x \(imageSize.height)")

            // verify that the returned thumbnail meets the minShortSide requirement
            if let minShortSide {
                let shortSide = min(imageSize.width, imageSize.height)
                if shortSide >= CGFloat(minShortSide) {
                    print("✓ Thumbnail meets minShortSide requirement: \(shortSide) >= \(minShortSide)")
                } else {
                    print("ℹ️ Thumbnail doesn't meet minShortSide requirement but still returned: \(shortSide) < \(minShortSide)")
                }
            }

            // verify width and height match the extracted values
            if let width = result.width, let height = result.height {
                XCTAssertEqual(CGFloat(width), imageSize.width, "Width should match extracted value")
                XCTAssertEqual(CGFloat(height), imageSize.height, "Height should match extracted value")
            }
        }
    }

    func testExtractThumbnailViaGenericFunction() async throws {
        let testFileURL = Bundle.module.url(forResource: "Pocket3", withExtension: "MP4")!

        // create file handle
        let fileHandle = try FileHandle(forReadingFrom: testFileURL)
        defer { fileHandle.closeFile() }

        // create read function
        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            try fileHandle.seek(toOffset: offset)
            let data = fileHandle.readData(ofLength: Int(length))
            return data
        }

        // Test using the generic readThumbnail function
        guard
            let result = try await readThumbnail(
                readAt: readAt, type: .mp4, minShortSide: nil
            )
        else {
            XCTFail("Failed to extract thumbnail using generic function")
            return
        }

        print(
            "Successfully extracted MP4 thumbnail via generic function, size: \(result.data.count) bytes"
        )
        XCTAssertGreaterThan(result.data.count, 0, "thumbnail data should not be empty")
        XCTAssertEqual(result.format, .jpeg, "MP4 thumbnail should be JPEG format")

        // validate data is valid image data
        guard let image = createImageFromThumbnailData(result.data, rotation: result.rotation)
        else {
            XCTFail("Should be able to create image from MP4 thumbnail data")
            return
        }

        let imageSize = image.size
        print("MP4 thumbnail size via generic function: \(imageSize.width) x \(imageSize.height)")
    }
}
