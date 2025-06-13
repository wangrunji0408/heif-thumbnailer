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

    func testExtractThumbnailWithMinShortSide() async throws {
        // get test file path
        guard let testFileURL = Bundle.module.url(forResource: "SonyHLG", withExtension: "HIF")
        else {
            XCTFail("fail to find SonyHLG.HIF")
            return
        }

        print("test file path: \(testFileURL.path)")

        // create file handle
        let fileHandle = try FileHandle(forReadingFrom: testFileURL)
        defer { fileHandle.closeFile() }

        // create read function
        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            try fileHandle.seek(toOffset: offset)
            let data = fileHandle.readData(ofLength: Int(length))
            return data
        }

        // test with different minShortSide values
        let testCases: [UInt32?] = [nil, 100, 200, 500, 1000]

        for minShortSide in testCases {
            print("\n--- Testing with minShortSide: \(minShortSide?.description ?? "nil") ---")

            do {
                let result = try await readHEICThumbnailWithRotation(
                    readAt: readAt, minShortSide: minShortSide)

                if let result = result {
                    print(
                        "success to extract thumbnail, size: \(result.data.count) bytes, rotation: \(result.rotation) degrees"
                    )
                    XCTAssertGreaterThan(result.data.count, 0, "thumbnail data should not be empty")

                    // validate data is valid image data
                    let image = createImageFromThumbnailData(result.data, rotation: result.rotation)
                    XCTAssertNotNil(image, "should be able to create image from thumbnail data")

                    if let image = image {
                        #if canImport(UIKit)
                            let imageSize = image.size
                            print("thumbnail size: \(imageSize.width) x \(imageSize.height)")
                            let shortSide = min(imageSize.width, imageSize.height)
                            print("short side: \(shortSide)")

                            // verify that the returned thumbnail meets the minShortSide requirement
                            if let minShortSide = minShortSide {
                                XCTAssertGreaterThanOrEqual(
                                    shortSide, CGFloat(minShortSide),
                                    "thumbnail short side should be >= \(minShortSide)")
                            }
                        #elseif canImport(AppKit)
                            let imageSize = image.size
                            print("thumbnail size: \(imageSize.width) x \(imageSize.height)")
                            let shortSide = min(imageSize.width, imageSize.height)
                            print("short side: \(shortSide)")

                            // verify that the returned thumbnail meets the minShortSide requirement
                            if let minShortSide = minShortSide {
                                XCTAssertGreaterThanOrEqual(
                                    shortSide, CGFloat(minShortSide),
                                    "thumbnail short side should be >= \(minShortSide)")
                            }
                        #endif
                    }

                } else {
                    if let minShortSide = minShortSide {
                        print(
                            "no thumbnail found that meets minShortSide requirement of \(minShortSide)"
                        )
                        // This might be expected if the requirement is too high
                    } else {
                        XCTFail("fail to extract thumbnail when no minShortSide specified")
                    }
                }
            } catch {
                XCTFail(
                    "fail to extract thumbnail with minShortSide \(minShortSide?.description ?? "nil"): \(error)"
                )
            }
        }
    }
}
