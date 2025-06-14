import Foundation
import XCTest

@testable import HeifThumbnailer

final class HeifThumbnailerTests: XCTestCase {
    func testExtractThumbnailSonyHLG() async throws {
        let testFileURL = Bundle.module.url(forResource: "SonyHLG", withExtension: "HIF")!

        // create file handle
        let fileHandle = try FileHandle(forReadingFrom: testFileURL)
        defer { fileHandle.closeFile() }

        // create read function
        var readCount = 0
        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            try fileHandle.seek(toOffset: offset)
            let data = fileHandle.readData(ofLength: Int(length))
            readCount += 1
            return data
        }

        // test with different minShortSide values
        for minShortSide in [nil as UInt32?, 100, 200, 500] {
            print("\n--- Testing with minShortSide: \(minShortSide?.description ?? "nil") ---")

            let lastReadCount = readCount
            guard
                let result = try await readHeifThumbnail(
                    readAt: readAt, minShortSide: minShortSide
                )
            else {
                XCTFail("fail to extract thumbnail")
                continue
            }
            let readCountToExtractThumbnail = readCount - lastReadCount
            XCTAssertEqual(
                readCountToExtractThumbnail, 2, "should read 2 times to extract thumbnail"
            )

            print(
                "success to extract thumbnail, size: \(result.data.count) bytes, rotation: \(result.rotation) degrees"
            )
            XCTAssertGreaterThan(result.data.count, 0, "thumbnail data should not be empty")

            // validate data is valid image data
            guard let image = createImageFromThumbnailData(result.data, rotation: result.rotation)
            else {
                XCTFail("should be able to create image from thumbnail data")
                continue
            }

            let imageSize = image.size
            print("thumbnail size: \(imageSize.width) x \(imageSize.height)")

            // verify that the returned thumbnail meets the minShortSide requirement
            if let minShortSide {
                let shortSide = min(imageSize.width, imageSize.height)
                XCTAssertGreaterThanOrEqual(
                    shortSide, CGFloat(minShortSide),
                    "thumbnail short side should be >= \(minShortSide)"
                )
            }
        }
    }

    func testExtractThumbnailiPhoneHEIC() async throws {
        let testFileURL = Bundle.module.url(forResource: "iPhone", withExtension: "HEIC")!

        // create file handle
        let fileHandle = try FileHandle(forReadingFrom: testFileURL)
        defer { fileHandle.closeFile() }

        // create read function
        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            try fileHandle.seek(toOffset: offset)
            let data = fileHandle.readData(ofLength: Int(length))
            return data
        }

        guard
            let result = try await readHeifThumbnail(readAt: readAt, minShortSide: nil)
        else {
            XCTFail("fail to extract thumbnail")
            return
        }

        print(
            "success to extract thumbnail, size: \(result.data.count) bytes, rotation: \(result.rotation) degrees"
        )
        XCTAssertGreaterThan(result.data.count, 0, "thumbnail data should not be empty")

        // validate data is valid image data
        guard let image = createImageFromThumbnailData(result.data, rotation: result.rotation)
        else {
            XCTFail("should be able to create image from thumbnail data")
            return
        }

        let imageSize = image.size
        print("thumbnail size: \(imageSize.width) x \(imageSize.height)")
    }
}
