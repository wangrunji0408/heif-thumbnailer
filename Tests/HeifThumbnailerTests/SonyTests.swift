import Foundation
@testable import HeifThumbnailer
import XCTest

final class SonyTests: XCTestCase {
    func testSonyArwThumbnailExtraction() async throws {
        // Get the test ARW file
        let testBundle = Bundle.module
        guard let arwURL = testBundle.url(forResource: "DSC04618", withExtension: "ARW") else {
            XCTFail("Test ARW file not found")
            return
        }

        // Create read function
        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            let fileHandle = try FileHandle(forReadingFrom: arwURL)
            defer { fileHandle.closeFile() }

            try fileHandle.seek(toOffset: offset)
            let data = fileHandle.readData(ofLength: Int(length))
            return data
        }

        // Test thumbnail extraction
        let thumbnail = try await readSonyArwThumbnail(readAt: readAt)

        XCTAssertNotNil(thumbnail, "Should extract thumbnail from ARW file")

        if let thumbnail = thumbnail {
            XCTAssertGreaterThan(thumbnail.data.count, 0, "Thumbnail data should not be empty")
            XCTAssertGreaterThan(thumbnail.width, 0, "Thumbnail width should be greater than 0")
            XCTAssertGreaterThan(thumbnail.height, 0, "Thumbnail height should be greater than 0")
            XCTAssertFalse(thumbnail.type.isEmpty, "Thumbnail type should not be empty")

            print("Extracted thumbnail: \(thumbnail.width)x\(thumbnail.height), type: \(thumbnail.type), size: \(thumbnail.data.count) bytes")
        }
    }

    func testSonyArwThumbnailExtractionWithMinSize() async throws {
        // Get the test ARW file
        let testBundle = Bundle.module
        guard let arwURL = testBundle.url(forResource: "DSC04618", withExtension: "ARW") else {
            XCTFail("Test ARW file not found")
            return
        }

        // Create read function
        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            let fileHandle = try FileHandle(forReadingFrom: arwURL)
            defer { fileHandle.closeFile() }

            try fileHandle.seek(toOffset: offset)
            let data = fileHandle.readData(ofLength: Int(length))
            return data
        }

        // Test thumbnail extraction with minimum size requirement
        let thumbnail = try await readSonyArwThumbnail(readAt: readAt, minShortSide: 500)

        XCTAssertNotNil(thumbnail, "Should extract thumbnail from ARW file with min size")

        if let thumbnail = thumbnail {
            let minSide = min(thumbnail.width, thumbnail.height)
            XCTAssertGreaterThanOrEqual(minSide, 500, "Thumbnail should meet minimum size requirement")

            print("Extracted thumbnail with min size: \(thumbnail.width)x\(thumbnail.height), type: \(thumbnail.type), size: \(thumbnail.data.count) bytes")
        }
    }

    func testSonyArwThumbnailAsImage() async throws {
        // Get the test ARW file
        let testBundle = Bundle.module
        guard let arwURL = testBundle.url(forResource: "DSC04618", withExtension: "ARW") else {
            XCTFail("Test ARW file not found")
            return
        }

        // Create read function
        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            let fileHandle = try FileHandle(forReadingFrom: arwURL)
            defer { fileHandle.closeFile() }

            try fileHandle.seek(toOffset: offset)
            let data = fileHandle.readData(ofLength: Int(length))
            return data
        }

        // Test thumbnail extraction as image
        let image = try await readSonyArwThumbnailAsImage(readAt: readAt)

        XCTAssertNotNil(image, "Should extract thumbnail as image from ARW file")

        if let image = image {
            #if canImport(UIKit)
                XCTAssertGreaterThan(image.size.width, 0, "Image width should be greater than 0")
                XCTAssertGreaterThan(image.size.height, 0, "Image height should be greater than 0")
                print("Extracted image: \(image.size.width)x\(image.size.height)")
            #elseif canImport(AppKit)
                XCTAssertGreaterThan(image.size.width, 0, "Image width should be greater than 0")
                XCTAssertGreaterThan(image.size.height, 0, "Image height should be greater than 0")
                print("Extracted image: \(image.size.width)x\(image.size.height)")
            #endif
        }
    }

    func testInvalidArwFile() async throws {
        // Test with invalid data
        let readAt: (UInt64, UInt32) async throws -> Data = { _, length in
            Data(repeating: 0, count: Int(length))
        }

        let thumbnail = try await readSonyArwThumbnail(readAt: readAt)
        XCTAssertNil(thumbnail, "Should return nil for invalid ARW data")
    }

    func testEmptyArwFile() async throws {
        // Test with empty data
        let readAt: (UInt64, UInt32) async throws -> Data = { _, _ in
            Data()
        }

        let thumbnail = try await readSonyArwThumbnail(readAt: readAt)
        XCTAssertNil(thumbnail, "Should return nil for empty ARW data")
    }
}
