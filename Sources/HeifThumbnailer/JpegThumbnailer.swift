import CoreGraphics
import Foundation
import ImageIO
import Logging

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

private let logger = Logger(label: "com.hdremote.JpegThumbnailer")

// MARK: - Public Types

public struct JpegThumbnail {
    public let data: Data
    public let width: UInt32
    public let height: UInt32
    public let type: String // "thumbnail" or "preview"
}

// MARK: - Internal Types

private struct ThumbnailEntry {
    let offset: UInt32
    let length: UInt32
    let type: String
    let width: UInt32?
    let height: UInt32?
}

private struct ExifHeader {
    let byteOrder: ByteOrder
    let ifdOffset: UInt32
}

private enum ByteOrder {
    case bigEndian
    case littleEndian
}

// MARK: - Public API

/// Extract thumbnail from JPEG file with minimal read operations
/// - Parameters:
///   - readAt: Async function to read data at specific offset and length
///   - minShortSide: Minimum short side length in pixels. Returns the most suitable thumbnail.
/// - Returns: Thumbnail data with metadata, or nil if extraction fails
public func readJpegThumbnail(
    readAt: @escaping (UInt64, UInt32) async throws -> Data,
    minShortSide: UInt32? = nil
) async throws -> JpegThumbnail? {
    // Step 1: Read JPEG header and find EXIF data and MPF data
    let headerData = try await readAt(0, 32768) // Read first 32KB to capture more segments
    guard let (exifData, exifOffset) = extractExifData(from: headerData) else {
        logger.error("No EXIF data found in JPEG file")
        return nil
    }

    logger.debug("Found EXIF data at offset \(exifOffset), size: \(exifData.count) bytes")

    // Step 2: Parse EXIF data to find thumbnail entries
    var thumbnailEntries = parseExifForThumbnails(exifData, exifOffset: exifOffset)

    // Step 3: Look for MPF data in APP2 segments
    let mpfEntries = extractMPFThumbnails(from: headerData)
    thumbnailEntries.append(contentsOf: mpfEntries)

    guard !thumbnailEntries.isEmpty else {
        logger.error("No thumbnails found in EXIF or MPF data")
        return nil
    }

    logger.debug("Found \(thumbnailEntries.count) total thumbnail entries")

    // Step 4: Find suitable thumbnail based on requirements
    guard let selectedEntry = findSuitableThumbnail(thumbnailEntries, minShortSide: minShortSide) else {
        logger.error("No thumbnail meets the requirements")
        return nil
    }

    // Step 5: Read thumbnail data
    let thumbnailData = try await readAt(UInt64(selectedEntry.offset), selectedEntry.length)

    // Step 6: Get thumbnail dimensions
    let (width, height) = getThumbnailDimensions(thumbnailData)

    return JpegThumbnail(
        data: thumbnailData,
        width: width,
        height: height,
        type: selectedEntry.type
    )
}

/// Convenience function to extract thumbnail as platform image
public func readJpegThumbnailAsImage(
    readAt: @escaping (UInt64, UInt32) async throws -> Data,
    minShortSide: UInt32? = nil
) async throws -> PlatformImage? {
    guard let thumbnail = try await readJpegThumbnail(readAt: readAt, minShortSide: minShortSide) else {
        return nil
    }
    return createImageFromThumbnailData(thumbnail.data)
}

// MARK: - EXIF Data Extraction

private func extractExifData(from data: Data) -> (Data, UInt32)? {
    guard data.count >= 4 else { return nil }

    // Check for JPEG SOI marker
    guard data[0] == 0xFF, data[1] == 0xD8 else {
        logger.error("Not a valid JPEG file")
        return nil
    }

    var offset = 2

    // Search for EXIF segment (APP1 with EXIF identifier)
    while offset + 4 < data.count {
        guard data[offset] == 0xFF else { break }

        let marker = data[offset + 1]
        let segmentLength = UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3])

        if marker == 0xE1 { // APP1 segment
            let segmentEnd = offset + 2 + Int(segmentLength)
            guard segmentEnd <= data.count else { break }

            let segmentData = data.subdata(in: offset + 4 ..< segmentEnd)
            if segmentData.count >= 6 {
                let exifIdentifier = segmentData.subdata(in: 0 ..< 4)
                if exifIdentifier == Data([0x45, 0x78, 0x69, 0x66]) { // "Exif"
                    logger.debug("Found EXIF data at offset \(offset + 4)")
                    let exifOffset = UInt32(offset + 10) // offset + 4 (segment header) + 6 (Exif\0\0)
                    return (segmentData.subdata(in: 6 ..< segmentData.count), exifOffset) // Skip "Exif\0\0"
                }
            }
        }

        if segmentLength < 2 { break }
        offset += 2 + Int(segmentLength)
    }

    return nil
}

// MARK: - EXIF Parsing

private func parseExifForThumbnails(_ exifData: Data, exifOffset: UInt32) -> [ThumbnailEntry] {
    guard exifData.count >= 8 else { return [] }

    // Parse TIFF header
    guard let header = parseExifHeader(exifData) else {
        logger.error("Failed to parse EXIF header")
        return []
    }

    var thumbnails: [ThumbnailEntry] = []

    // Parse IFD0 (main image)
    if let ifd0Offset = parseIFD(exifData, offset: Int(header.ifdOffset), byteOrder: header.byteOrder, exifOffset: exifOffset, thumbnails: &thumbnails) {
        // Look for IFD1 (thumbnail)
        if ifd0Offset > 0 {
            _ = parseIFD(exifData, offset: ifd0Offset, byteOrder: header.byteOrder, exifOffset: exifOffset, isThumbnail: true, thumbnails: &thumbnails)
        }
    }

    return thumbnails
}

private func parseExifHeader(_ data: Data) -> ExifHeader? {
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

    // Read IFD offset
    let ifdOffset = readUInt32(data, offset: 4, byteOrder: byteOrder)

    return ExifHeader(byteOrder: byteOrder, ifdOffset: ifdOffset)
}

private func parseIFD(_ data: Data, offset: Int, byteOrder: ByteOrder, exifOffset: UInt32, isThumbnail: Bool = false, thumbnails: inout [ThumbnailEntry]) -> Int? {
    guard offset + 2 <= data.count else { return nil }

    let entryCount = readUInt16(data, offset: offset, byteOrder: byteOrder)
    var currentOffset = offset + 2

    var thumbnailOffset: UInt32?
    var thumbnailLength: UInt32?
    var thumbnailWidth: UInt32?
    var thumbnailHeight: UInt32?

    logger.debug("Parsing IFD at offset \(offset), isThumbnail: \(isThumbnail), entryCount: \(entryCount)")

    // Parse directory entries
    for _ in 0 ..< entryCount {
        guard currentOffset + 12 <= data.count else { break }

        let tag = readUInt16(data, offset: currentOffset, byteOrder: byteOrder)
        _ = readUInt16(data, offset: currentOffset + 2, byteOrder: byteOrder) // type - not used
        _ = readUInt32(data, offset: currentOffset + 4, byteOrder: byteOrder) // count - not used
        let valueOffset = readUInt32(data, offset: currentOffset + 8, byteOrder: byteOrder)

        if isThumbnail {
            switch tag {
            case 0x0201: // JPEGInterchangeFormat (thumbnail offset)
                thumbnailOffset = valueOffset
                logger.debug("Found JPEGInterchangeFormat: \(valueOffset)")
            case 0x0202: // JPEGInterchangeFormatLength (thumbnail length)
                thumbnailLength = valueOffset
                logger.debug("Found JPEGInterchangeFormatLength: \(valueOffset)")
            case 0x0100: // ImageWidth
                thumbnailWidth = valueOffset
                logger.debug("Found thumbnail ImageWidth: \(valueOffset)")
            case 0x0101: // ImageLength (Height)
                thumbnailHeight = valueOffset
                logger.debug("Found thumbnail ImageLength: \(valueOffset)")
            default:
                break
            }
        }

        currentOffset += 12
    }

    // If this is a thumbnail IFD and we found both offset and length
    if isThumbnail, let relativeOffset = thumbnailOffset, let length = thumbnailLength {
        // Convert relative offset to absolute offset
        // EXIF offsets are relative to the start of the TIFF header, which is at exifOffset
        let absoluteOffset = exifOffset + relativeOffset
        let entry = ThumbnailEntry(
            offset: absoluteOffset,
            length: length,
            type: "thumbnail",
            width: thumbnailWidth,
            height: thumbnailHeight
        )
        thumbnails.append(entry)
        logger.debug("Found thumbnail: relativeOffset=\(relativeOffset), absoluteOffset=\(absoluteOffset), length=\(length), width=\(thumbnailWidth ?? 0), height=\(thumbnailHeight ?? 0)")
    }

    // Read next IFD offset
    guard currentOffset + 4 <= data.count else { return nil }
    let nextIFDOffset = readUInt32(data, offset: currentOffset, byteOrder: byteOrder)
    return nextIFDOffset > 0 ? Int(nextIFDOffset) : nil
}

// MARK: - MPF Data Extraction

private func extractMPFThumbnails(from data: Data) -> [ThumbnailEntry] {
    var thumbnails: [ThumbnailEntry] = []
    var offset = 2 // Skip JPEG SOI marker

    // Search for APP2 segments that contain MPF data
    while offset + 4 < data.count {
        guard data[offset] == 0xFF else { break }

        let marker = data[offset + 1]
        let segmentLength = UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3])

        if marker == 0xE2 { // APP2 segment
            let segmentEnd = offset + 2 + Int(segmentLength)
            guard segmentEnd <= data.count else { break }

            let segmentData = data.subdata(in: offset + 4 ..< segmentEnd)
            if segmentData.count >= 4 {
                let mpfIdentifier = segmentData.subdata(in: 0 ..< 4)
                // Check for both "MPF\0" and "MPF " (space) variants
                if mpfIdentifier == Data([0x4D, 0x50, 0x46, 0x00]) || // "MPF\0"
                    mpfIdentifier == Data([0x4D, 0x50, 0x46, 0x20])
                { // "MPF "
                    logger.debug("Found MPF data in APP2 segment at offset \(offset + 4), segment size: \(segmentData.count)")
                    let mpfOffset = UInt32(offset + 4)
                    let mpfEntries = parseMPFData(segmentData, mpfOffset: mpfOffset)
                    logger.debug("MPF parsing returned \(mpfEntries.count) entries")
                    thumbnails.append(contentsOf: mpfEntries)
                }
            }
        }

        if segmentLength < 2 { break }
        offset += 2 + Int(segmentLength)
    }

    return thumbnails
}

private func parseMPFData(_ mpfData: Data, mpfOffset: UInt32) -> [ThumbnailEntry] {
    var thumbnails: [ThumbnailEntry] = []
    guard mpfData.count >= 12 else {
        logger.debug("MPF data too small: \(mpfData.count) bytes")
        return thumbnails
    }

    // Parse MPF header
    var offset = 4 // Skip "MPF\0" or "MPF "

    logger.debug("MPF data size: \(mpfData.count) bytes, starting at offset \(offset)")

    // Parse TIFF header within MPF
    let tiffData = mpfData.subdata(in: offset ..< mpfData.count)
    guard let header = parseExifHeader(tiffData) else {
        logger.error("Failed to parse MPF TIFF header")
        return thumbnails
    }

    logger.debug("MPF TIFF header parsed, byte order: \(header.byteOrder), IFD offset: \(header.ifdOffset)")
    offset += 8 // Skip TIFF header

    // Parse MP Index IFD
    // The IFD offset is relative to the start of the TIFF header
    let tiffHeaderStart = 4 // TIFF header starts after "MPF " identifier
    let mpIndexIFDOffset = tiffHeaderStart + Int(header.ifdOffset)
    guard mpIndexIFDOffset + 2 <= mpfData.count else {
        logger.error("MP Index IFD offset out of bounds: \(mpIndexIFDOffset), data size: \(mpfData.count)")
        return thumbnails
    }

    let entryCount = readUInt16(mpfData, offset: mpIndexIFDOffset, byteOrder: header.byteOrder)
    var currentOffset = mpIndexIFDOffset + 2

    logger.debug("MPF Index IFD at offset \(mpIndexIFDOffset) has \(entryCount) entries")

    var numberOfImages: UInt32 = 0
    var mpEntryOffset: UInt32 = 0

    // Parse MP Index IFD entries
    for _ in 0 ..< entryCount {
        guard currentOffset + 12 <= mpfData.count else { break }

        let tag = readUInt16(mpfData, offset: currentOffset, byteOrder: header.byteOrder)
        let type = readUInt16(mpfData, offset: currentOffset + 2, byteOrder: header.byteOrder)
        let count = readUInt32(mpfData, offset: currentOffset + 4, byteOrder: header.byteOrder)
        let valueOffset = readUInt32(mpfData, offset: currentOffset + 8, byteOrder: header.byteOrder)

        switch tag {
        case 0xB000: // MP Format Version
            logger.debug("MP Format Version found")
        case 0xB001: // Number of Images
            numberOfImages = valueOffset
            logger.debug("Number of Images: \(numberOfImages)")
        case 0xB002: // MP Entry
            if type == 7, count > 0 { // UNDEFINED type with count > 0
                // MP Entry data is stored at valueOffset if count <= 4, otherwise at the offset pointed by valueOffset
                if count <= 4 {
                    mpEntryOffset = valueOffset
                } else {
                    // The offset is relative to the start of the TIFF header
                    mpEntryOffset = valueOffset + UInt32(tiffHeaderStart)
                }
                logger.debug("MP Entry offset: \(mpEntryOffset), count: \(count), type: \(type)")
            }
        default:
            break
        }

        currentOffset += 12
    }

    // Parse MP Entry data
    if numberOfImages > 0, mpEntryOffset > 0 {
        let mpEntries = parseMPEntries(mpfData, entryOffset: Int(mpEntryOffset), numberOfImages: Int(numberOfImages), byteOrder: header.byteOrder, mpfOffset: mpfOffset)
        thumbnails.append(contentsOf: mpEntries)
    }

    return thumbnails
}

private func parseMPEntries(_ data: Data, entryOffset: Int, numberOfImages: Int, byteOrder: ByteOrder, mpfOffset _: UInt32) -> [ThumbnailEntry] {
    var thumbnails: [ThumbnailEntry] = []
    var offset = entryOffset

    logger.debug("Parsing \(numberOfImages) MP entries at offset \(entryOffset)")

    for i in 0 ..< numberOfImages {
        guard offset + 16 <= data.count else { break }

        let imageAttributes = readUInt32(data, offset: offset, byteOrder: byteOrder)
        let imageSize = readUInt32(data, offset: offset + 4, byteOrder: byteOrder)
        let imageOffset = readUInt32(data, offset: offset + 8, byteOrder: byteOrder)
        let dependentImage1 = readUInt16(data, offset: offset + 12, byteOrder: byteOrder)
        let dependentImage2 = readUInt16(data, offset: offset + 14, byteOrder: byteOrder)

        logger.debug("MP Entry \(i): attributes=0x\(String(imageAttributes, radix: 16)), size=\(imageSize), offset=\(imageOffset)")

        // Check if this is a valid image entry
        if imageSize > 0, imageSize < 50_000_000 { // Reasonable size check
            let imageType = (imageAttributes & 0x7000000) >> 24
            let imageFormat = (imageAttributes & 0x7000) >> 12

            // Determine image type
            let entryType: String
            if i == 0 {
                entryType = "primary" // First image is usually the primary image
            } else if imageType == 0 {
                entryType = "thumbnail" // Type 0 is typically thumbnail
            } else {
                entryType = "preview" // Other types are previews
            }

            // Calculate absolute offset
            let absoluteOffset: UInt32
            if imageOffset == 0 {
                // Offset 0 means this is the primary image at the start of the file
                absoluteOffset = 0
            } else {
                // Other offsets are relative to the start of the file
                absoluteOffset = imageOffset
            }

            // Skip the primary image (offset 0) as it's not a thumbnail
            if absoluteOffset > 0 {
                let entry = ThumbnailEntry(
                    offset: absoluteOffset,
                    length: imageSize,
                    type: entryType,
                    width: nil, // MPF doesn't provide dimensions in header
                    height: nil
                )
                thumbnails.append(entry)
                logger.debug("Found MPF \(entryType): offset=\(absoluteOffset), size=\(imageSize)")
            }
        }

        offset += 16
    }

    return thumbnails
}

// MARK: - Thumbnail Selection

private func findSuitableThumbnail(_ thumbnails: [ThumbnailEntry], minShortSide: UInt32?) -> ThumbnailEntry? {
    guard !thumbnails.isEmpty else { return nil }

    // If no specific size requirement, return the smallest thumbnail
    guard let minShortSide = minShortSide else {
        return thumbnails.min { $0.length < $1.length }
    }

    logger.debug("Finding suitable thumbnail for minShortSide: \(minShortSide)")

    // Filter thumbnails that meet the size requirement
    let suitableThumbnails = thumbnails.filter { entry in
        guard let width = entry.width, let height = entry.height else {
            // If we don't have dimensions, assume it might be suitable
            logger.debug("Thumbnail \(entry.type) has no dimensions, assuming suitable")
            return true
        }

        let shortSide = min(width, height)
        let isSuitable = shortSide >= minShortSide
        logger.debug("Thumbnail \(entry.type): \(width)x\(height), shortSide=\(shortSide), suitable=\(isSuitable)")
        return isSuitable
    }

    // If we have suitable thumbnails, prefer the smallest one that meets requirements
    if !suitableThumbnails.isEmpty {
        let selected = suitableThumbnails.min { entry1, entry2 in
            // First, prefer thumbnails with known dimensions
            let entry1HasDimensions = entry1.width != nil && entry1.height != nil
            let entry2HasDimensions = entry2.width != nil && entry2.height != nil

            if entry1HasDimensions, !entry2HasDimensions {
                return true
            } else if !entry1HasDimensions, entry2HasDimensions {
                return false
            }

            // If both have dimensions, prefer the one with smaller short side (but still >= minShortSide)
            if let w1 = entry1.width, let h1 = entry1.height,
               let w2 = entry2.width, let h2 = entry2.height
            {
                let shortSide1 = min(w1, h1)
                let shortSide2 = min(w2, h2)
                return shortSide1 < shortSide2
            }

            // Fall back to file size comparison
            return entry1.length < entry2.length
        }

        if let selected = selected {
            logger.debug("Selected thumbnail: \(selected.type), size: \(selected.width ?? 0)x\(selected.height ?? 0)")
        }
        return selected
    }

    // If no thumbnails meet the size requirement, return the largest available
    let largest = thumbnails.max { entry1, entry2 in
        // Prefer thumbnails with known dimensions
        let entry1HasDimensions = entry1.width != nil && entry1.height != nil
        let entry2HasDimensions = entry2.width != nil && entry2.height != nil

        if entry1HasDimensions, !entry2HasDimensions {
            return false
        } else if !entry1HasDimensions, entry2HasDimensions {
            return true
        }

        // If both have dimensions, prefer the larger one
        if let w1 = entry1.width, let h1 = entry1.height,
           let w2 = entry2.width, let h2 = entry2.height
        {
            let shortSide1 = min(w1, h1)
            let shortSide2 = min(w2, h2)
            return shortSide1 < shortSide2
        }

        // Fall back to file size comparison
        return entry1.length < entry2.length
    }

    logger.warning("No thumbnail meets minShortSide requirement, returning largest available")
    if let largest = largest {
        logger.debug("Selected largest thumbnail: \(largest.type), size: \(largest.width ?? 0)x\(largest.height ?? 0)")
    }
    return largest
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

private func getThumbnailDimensions(_ data: Data) -> (width: UInt32, height: UInt32) {
    guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
          let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber
    else {
        return (0, 0)
    }

    return (UInt32(width.intValue), UInt32(height.intValue))
}
