import CoreGraphics
import Foundation
import ImageIO
import Logging

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

private let logger = Logger(label: "com.hdremote.SonyArwThumbnailer")

// MARK: - Internal Types

private struct ThumbnailEntry {
    let offset: UInt32
    let length: UInt32
    let type: String
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

// MARK: - Public API

/// Extract thumbnail from Sony ARW file with minimal read operations
/// - Parameters:
///   - readAt: Async function to read data at specific offset and length
///   - minShortSide: Minimum short side length in pixels. Returns the most suitable thumbnail.
/// - Returns: Thumbnail data with metadata, or nil if extraction fails
func readSonyArwThumbnail(
    readAt: @escaping (UInt64, UInt32) async throws -> Data,
    minShortSide: UInt32? = nil
) async throws -> Thumbnail? {
    // Step 1: Read TIFF header and validate ARW format
    let headerData = try await readAt(0, 65536) // Read first 64KB to capture IFDs
    guard let header = parseTiffHeader(headerData) else {
        logger.error("Not a valid TIFF/ARW file")
        return nil
    }

    logger.debug("ARW file detected with byte order: \(header.byteOrder)")

    // Step 2: Parse IFDs to find thumbnail entries
    var thumbnailEntries: [ThumbnailEntry] = []

    // Parse IFD0 (main image)
    var currentIfdOffset = Int(header.ifdOffset)
    var ifdIndex = 0

    while currentIfdOffset > 0, currentIfdOffset < headerData.count, ifdIndex < 10 {
        let nextIfdOffset = parseIFD(
            headerData,
            offset: currentIfdOffset,
            byteOrder: header.byteOrder,
            isThumbnail: ifdIndex > 0, // IFD1+ are typically thumbnails
            thumbnails: &thumbnailEntries
        )

        currentIfdOffset = nextIfdOffset
        ifdIndex += 1
    }

    guard !thumbnailEntries.isEmpty else {
        logger.error("No thumbnails found in ARW file")
        return nil
    }

    logger.debug("Found \(thumbnailEntries.count) thumbnail entries")

    // Step 4: Select the most suitable thumbnail
    let selectedEntry = selectBestThumbnail(thumbnailEntries, minShortSide: minShortSide)

    // Step 5: Read thumbnail data
    let thumbnailData = try await readAt(UInt64(selectedEntry.offset), selectedEntry.length)

    // Step 6: Get thumbnail dimensions if not already known
    let (width, height) = selectedEntry.width != nil && selectedEntry.height != nil
        ? (selectedEntry.width!, selectedEntry.height!)
        : getThumbnailDimensions(thumbnailData)

    return Thumbnail(
        data: thumbnailData,
        format: .jpeg,
        width: width,
        height: height,
        rotation: 0
    )
}

/// Convenience function to extract thumbnail as platform image
public func readSonyArwThumbnailAsImage(
    readAt: @escaping (UInt64, UInt32) async throws -> Data,
    minShortSide: UInt32? = nil
) async throws -> PlatformImage? {
    guard let thumbnail = try await readSonyArwThumbnail(readAt: readAt, minShortSide: minShortSide) else {
        return nil
    }
    return createImageFromThumbnailData(thumbnail.data)
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
    isThumbnail: Bool = false,
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
            type: isThumbnail ? "thumbnail" : "preview",
            width: imageWidth,
            height: imageHeight
        ))
        logger.debug("Found JPEG thumbnail: offset=\(offset), length=\(length)")
    } else if let offset = thumbnailOffset, let length = thumbnailLength {
        thumbnails.append(ThumbnailEntry(
            offset: offset,
            length: length,
            type: isThumbnail ? "thumbnail" : "preview",
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

private func selectBestThumbnail(_ thumbnails: [ThumbnailEntry], minShortSide: UInt32?) -> ThumbnailEntry {
    guard let minShortSide = minShortSide else {
        // Return the largest thumbnail if no minimum size specified
        return thumbnails.max { entry1, entry2 in
            entry1.length < entry2.length
        } ?? thumbnails.first!
    }

    // Sort thumbnails by size (largest first) to prioritize larger thumbnails
    let sortedThumbnails = thumbnails.sorted { entry1, entry2 in
        entry1.length > entry2.length
    }

    // Find the first thumbnail that meets the minimum size requirement
    for thumbnail in sortedThumbnails {
        // If we don't have dimensions, assume it might be suitable and check later
        guard let width = thumbnail.width, let height = thumbnail.height else {
            continue
        }

        if min(width, height) >= minShortSide {
            return thumbnail
        }
    }

    // If no thumbnail meets the requirement, return the largest one
    return sortedThumbnails.first ?? thumbnails.first!
}

private func getThumbnailDimensions(_ data: Data) -> (UInt32, UInt32) {
    guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
          let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber
    else {
        return (0, 0)
    }

    return (UInt32(width.intValue), UInt32(height.intValue))
}

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
