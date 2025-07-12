import CoreGraphics
import Foundation
import ImageIO
import Logging

private let logger = Logger(label: "com.hdremote.SonyArwThumbnailer")

// MARK: - SonyArwReader Implementation

public class SonyArwReader: ImageReader {
    private let readAt: (UInt64, UInt32) async throws -> Data
    private var thumbnailEntries: [ThumbnailEntry]?
    private var metadata: Metadata?

    public required init(readAt: @escaping (UInt64, UInt32) async throws -> Data) {
        self.readAt = readAt
    }

    public func getThumbnailList() async throws -> [ThumbnailInfo] {
        if thumbnailEntries == nil {
            try await loadThumbnailEntries()
        }

        return thumbnailEntries?.map { entry in
            ThumbnailInfo(
                size: entry.length,
                format: "jpeg",
                width: entry.width,
                height: entry.height,
                rotation: nil
            )
        } ?? []
    }

    public func getThumbnail(at index: Int) async throws -> Data {
        if thumbnailEntries == nil {
            try await loadThumbnailEntries()
        }

        guard let entries = thumbnailEntries, index < entries.count else {
            throw ImageReaderError.indexOutOfBounds
        }

        let entry = entries[index]
        return try await readAt(UInt64(entry.offset), entry.length)
    }

    public func getMetadata() async throws -> Metadata? {
        if metadata == nil {
            try await loadMetadata()
        }
        return metadata
    }

    private func loadThumbnailEntries() async throws {
        // Read TIFF header and validate ARW format
        let headerData = try await readAt(0, 65536)
        guard let header = parseTiffHeader(headerData) else {
            throw ImageReaderError.invalidData
        }

        // Parse IFDs to find thumbnail entries
        var entries: [ThumbnailEntry] = []
        var currentIfdOffset = Int(header.ifdOffset)
        var ifdIndex = 0

        while currentIfdOffset > 0, currentIfdOffset < headerData.count, ifdIndex < 10 {
            let nextIfdOffset = parseIFD(
                headerData,
                offset: currentIfdOffset,
                byteOrder: header.byteOrder,
                isThumbnail: ifdIndex > 0,
                thumbnails: &entries
            )

            currentIfdOffset = nextIfdOffset
            ifdIndex += 1
        }

        thumbnailEntries = entries
    }

    private func loadMetadata() async throws {
        // For ARW files, we can get metadata from the main image
        if let entries = thumbnailEntries, let firstEntry = entries.first,
           let width = firstEntry.width, let height = firstEntry.height
        {
            metadata = Metadata(width: width, height: height)
        }
    }
}

// MARK: - Internal Types

private struct ThumbnailEntry {
    let offset: UInt32
    let length: UInt32
    let width: UInt32?
    let height: UInt32?
}

private struct TiffHeader {
    let byteOrder: ByteOrder
    let ifdOffset: UInt32
}

private enum ByteOrder {
    case bigEndian
    case littleEndian
}

// MARK: - TIFF Header Parsing

private func parseTiffHeader(_ data: Data) -> TiffHeader? {
    guard data.count >= 8 else { return nil }

    // Check byte order
    let byteOrder: ByteOrder
    if data[0] == 0x49, data[1] == 0x49 { // "II" - Intel (little endian)
        byteOrder = .littleEndian
    } else if data[0] == 0x4D, data[1] == 0x4D { // "MM" - Motorola (big endian)
        byteOrder = .bigEndian
    } else {
        return nil
    }

    // Check magic number (42)
    let magic = readUInt16(data, offset: 2, byteOrder: byteOrder)
    guard magic == 42 else { return nil }

    // Get IFD offset
    let ifdOffset = readUInt32(data, offset: 4, byteOrder: byteOrder)

    return TiffHeader(byteOrder: byteOrder, ifdOffset: ifdOffset)
}

// MARK: - IFD Parsing

private func parseIFD(
    _ data: Data,
    offset: Int,
    byteOrder: ByteOrder,
    isThumbnail _: Bool = false,
    thumbnails: inout [ThumbnailEntry]
) -> Int {
    guard offset + 2 <= data.count else { return 0 }

    let entryCount = readUInt16(data, offset: offset, byteOrder: byteOrder)
    let entriesStart = offset + 2
    let entriesEnd = entriesStart + Int(entryCount) * 12

    guard entriesEnd <= data.count else { return 0 }

    var thumbnailOffset: UInt32?
    var thumbnailLength: UInt32?
    var imageWidth: UInt32?
    var imageHeight: UInt32?
    var jpegInterchangeFormat: UInt32?
    var jpegInterchangeFormatLength: UInt32?

    // Parse directory entries
    for i in 0 ..< entryCount {
        let entryOffset = entriesStart + Int(i) * 12
        let tag = readUInt16(data, offset: entryOffset, byteOrder: byteOrder)
        let type = readUInt16(data, offset: entryOffset + 2, byteOrder: byteOrder)
        let count = readUInt32(data, offset: entryOffset + 4, byteOrder: byteOrder)
        let valueOffset = entryOffset + 8

        switch tag {
        case 0x0100: // ImageWidth
            imageWidth = readTagValue(data, offset: valueOffset, type: type, count: count, byteOrder: byteOrder)
        case 0x0101: // ImageHeight
            imageHeight = readTagValue(data, offset: valueOffset, type: type, count: count, byteOrder: byteOrder)
        case 0x0111: // StripOffsets
            thumbnailOffset = readTagValue(data, offset: valueOffset, type: type, count: count, byteOrder: byteOrder)
        case 0x0117: // StripByteCounts
            thumbnailLength = readTagValue(data, offset: valueOffset, type: type, count: count, byteOrder: byteOrder)
        case 0x0201: // JPEGInterchangeFormat (thumbnail offset)
            jpegInterchangeFormat = readTagValue(data, offset: valueOffset, type: type, count: count, byteOrder: byteOrder)
        case 0x0202: // JPEGInterchangeFormatLength (thumbnail length)
            jpegInterchangeFormatLength = readTagValue(data, offset: valueOffset, type: type, count: count, byteOrder: byteOrder)
        default:
            break
        }
    }

    // Add thumbnail entries
    if let offset = jpegInterchangeFormat, let length = jpegInterchangeFormatLength {
        thumbnails.append(ThumbnailEntry(
            offset: offset,
            length: length,
            width: imageWidth,
            height: imageHeight
        ))
        logger.debug("Found JPEG thumbnail: offset=\(offset), length=\(length)")
    } else if let offset = thumbnailOffset, let length = thumbnailLength {
        thumbnails.append(ThumbnailEntry(
            offset: offset,
            length: length,
            width: imageWidth,
            height: imageHeight
        ))
        logger.debug("Found strip thumbnail: offset=\(offset), length=\(length)")
    }

    // Get next IFD offset
    let nextIfdOffset = readUInt32(data, offset: entriesEnd, byteOrder: byteOrder)
    return nextIfdOffset > 0 ? Int(nextIfdOffset) : 0
}

// MARK: - Utility Functions

private func readUInt16(_ data: Data, offset: Int, byteOrder: ByteOrder) -> UInt16 {
    guard offset + 2 <= data.count else { return 0 }

    let bytes = data.subdata(in: offset ..< offset + 2)
    switch byteOrder {
    case .littleEndian:
        return bytes.withUnsafeBytes { $0.load(as: UInt16.self) }
    case .bigEndian:
        return bytes.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
    }
}

private func readUInt32(_ data: Data, offset: Int, byteOrder: ByteOrder) -> UInt32 {
    guard offset + 4 <= data.count else { return 0 }

    let bytes = data.subdata(in: offset ..< offset + 4)
    switch byteOrder {
    case .littleEndian:
        return bytes.withUnsafeBytes { $0.load(as: UInt32.self) }
    case .bigEndian:
        return bytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }
}

private func readTagValue(_ data: Data, offset: Int, type: UInt16, count: UInt32, byteOrder: ByteOrder) -> UInt32? {
    // Handle different TIFF data types
    switch type {
    case 3: // SHORT
        if count == 1 {
            return UInt32(readUInt16(data, offset: offset, byteOrder: byteOrder))
        }
    case 4: // LONG
        if count == 1 {
            return readUInt32(data, offset: offset, byteOrder: byteOrder)
        }
    default:
        break
    }

    return nil
}
