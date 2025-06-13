import Foundation
import XCTest

@testable import HEICThumbnailExtractor

final class HEICThumbnailExtractorTests: XCTestCase {

    func testExtractThumbnailSonyHLG() async throws {
        // get test file path
        guard let testFileURL = Bundle.module.url(forResource: "SonyHLG", withExtension: "HIF")
        else {
            XCTFail("fail to find SonyHLG.HIF")
            return
        }

        print("test file path: \(testFileURL.path)")

        // validate file exists
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: testFileURL.path), "test file not found")

        // get file size
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: testFileURL.path)
        let fileSize = fileAttributes[.size] as? Int64 ?? 0
        print("file size: \(fileSize) bytes")

        // create file handle
        let fileHandle = try FileHandle(forReadingFrom: testFileURL)
        defer { fileHandle.closeFile() }

        // create read function
        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            try fileHandle.seek(toOffset: offset)
            let data = fileHandle.readData(ofLength: Int(length))
            print("read offset \(offset), length \(length), actual read \(data.count) bytes")
            return data
        }

        // test thumbnail extraction
        do {
            let thumbnailData = try await readHEICThumbnail(readAt: readAt)

            if let thumbnailData = thumbnailData {
                print("success to extract thumbnail, size: \(thumbnailData.count) bytes")
                XCTAssertGreaterThan(thumbnailData.count, 0, "thumbnail data should not be empty")

                // validate data is valid image data
                let image = createImageFromThumbnailData(thumbnailData)
                XCTAssertNotNil(image, "should be able to create image from thumbnail data")

                if let image = image {
                    #if canImport(UIKit)
                        print("thumbnail size: \(image.size.width) x \(image.size.height)")
                        XCTAssertGreaterThan(image.size.width, 0)
                        XCTAssertGreaterThan(image.size.height, 0)
                    #elseif canImport(AppKit)
                        print("thumbnail size: \(image.size.width) x \(image.size.height)")
                        XCTAssertGreaterThan(image.size.width, 0)
                        XCTAssertGreaterThan(image.size.height, 0)
                    #endif
                }

                // save thumbnail to temporary file for validation
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "test_thumbnail.jpg")
                try thumbnailData.write(to: tempURL)
                print("test thumbnail saved to \(tempURL.path)")

            } else {
                XCTFail("fail to extract thumbnail")
            }
        } catch {
            XCTFail("fail to extract thumbnail: \(error)")
        }
    }
}
