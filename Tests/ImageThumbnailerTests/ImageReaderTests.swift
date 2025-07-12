@testable import ImageThumbnailer
import XCTest

final class ImageReaderTests: XCTestCase {
    func testHeifReader() async throws {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "iPhone", withExtension: "HEIC") else {
            XCTFail("Test file not found")
            return
        }

        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            let fileHandle = try FileHandle(forReadingFrom: url)
            defer { fileHandle.closeFile() }

            try fileHandle.seek(toOffset: offset)
            return fileHandle.readData(ofLength: Int(length))
        }

        let reader = HeifReader(readAt: readAt)

        // Test getThumbnailList
        let thumbnailList = try await reader.getThumbnailList()
        XCTAssertFalse(thumbnailList.isEmpty, "Should find at least one thumbnail")

        // Test getMetadata
        let metadata = try await reader.getMetadata()
        XCTAssertNotNil(metadata, "Should have metadata")
        XCTAssertGreaterThan(metadata?.width ?? 0, 0, "Width should be greater than 0")
        XCTAssertGreaterThan(metadata?.height ?? 0, 0, "Height should be greater than 0")

        // Test getThumbnail
        let thumbnailData = try await reader.getThumbnail(at: 0)
        XCTAssertFalse(thumbnailData.isEmpty, "Thumbnail data should not be empty")

        // Test invalid index
        do {
            _ = try await reader.getThumbnail(at: 999)
            XCTFail("Should throw error for invalid index")
        } catch ImageReaderError.indexOutOfBounds {
            // Expected
        } catch {
            XCTFail("Should throw indexOutOfBounds error, got \(error)")
        }
    }

    func testJpegReader() async throws {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "iPhone5", withExtension: "JPG") else {
            XCTFail("Test file not found")
            return
        }

        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            let fileHandle = try FileHandle(forReadingFrom: url)
            defer { fileHandle.closeFile() }

            try fileHandle.seek(toOffset: offset)
            return fileHandle.readData(ofLength: Int(length))
        }

        let reader = JpegReader(readAt: readAt)

        // Test getThumbnailList
        let thumbnailList = try await reader.getThumbnailList()
        XCTAssertFalse(thumbnailList.isEmpty, "Should find at least one thumbnail")

        // Test getThumbnail
        let thumbnailData = try await reader.getThumbnail(at: 0)
        XCTAssertFalse(thumbnailData.isEmpty, "Thumbnail data should not be empty")
    }

    func testSonyArwReader() async throws {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "DSC04618", withExtension: "ARW") else {
            XCTFail("Test file not found")
            return
        }

        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            let fileHandle = try FileHandle(forReadingFrom: url)
            defer { fileHandle.closeFile() }

            try fileHandle.seek(toOffset: offset)
            return fileHandle.readData(ofLength: Int(length))
        }

        let reader = SonyArwReader(readAt: readAt)

        // Test getThumbnailList
        let thumbnailList = try await reader.getThumbnailList()
        XCTAssertFalse(thumbnailList.isEmpty, "Should find at least one thumbnail")

        // Test getThumbnail
        let thumbnailData = try await reader.getThumbnail(at: 0)
        XCTAssertFalse(thumbnailData.isEmpty, "Thumbnail data should not be empty")
    }

    func testMp4Reader() async throws {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "Pocket3", withExtension: "MP4") else {
            XCTFail("Test file not found")
            return
        }

        let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
            let fileHandle = try FileHandle(forReadingFrom: url)
            defer { fileHandle.closeFile() }

            try fileHandle.seek(toOffset: offset)
            return fileHandle.readData(ofLength: Int(length))
        }

        let reader = Mp4Reader(readAt: readAt)

        // Test getThumbnailList
        let thumbnailList = try await reader.getThumbnailList()
        XCTAssertFalse(thumbnailList.isEmpty, "Should find at least one thumbnail")

        // Test getMetadata
        let metadata = try await reader.getMetadata()
        XCTAssertNotNil(metadata, "Should have metadata")

        // Test getThumbnail
        let thumbnailData = try await reader.getThumbnail(at: 0)
        XCTAssertFalse(thumbnailData.isEmpty, "Thumbnail data should not be empty")
    }
}
