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

// MARK: - Internal Types

private struct ThumbnailEntry {
    let offset: UInt32
    let length: UInt32
    let type: String
    let width: UInt32?
    let height: UInt32?
}

private struct MPImageEntry {
    let flags: UInt32 // bits 31-27: image flags
    let format: UInt32 // bits 26-24: image format (0=JPEG)
    let type: UInt32 // bits 23-0: image type
    let length: UInt32 // image size in bytes
    let start: UInt32 // image offset
    let dependent1: UInt16 // dependent image 1 entry number
    let dependent2: UInt16 // dependent image 2 entry number
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
func readJpegThumbnail(
    readAt: @escaping (UInt64, UInt32) async throws -> Data,
    minShortSide: UInt32? = nil
) async throws -> Thumbnail? {
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
    let selectedEntry: ThumbnailEntry
    if minShortSide == nil || minShortSide! < 100 {
        selectedEntry = thumbnailEntries.first!
    } else {
        selectedEntry = thumbnailEntries.last!
    }

    // Step 5: Read thumbnail data
    let thumbnailData = try await readAt(UInt64(selectedEntry.offset), selectedEntry.length)

    // Step 6: Get thumbnail dimensions
    let (width, height) = getThumbnailDimensions(thumbnailData)

    return Thumbnail(
        data: thumbnailData,
        format: .jpeg,
        width: width,
        height: height,
        rotation: 0
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
                // MP Entry data location depends on the count
                if count <= 4 {
                    // Data is stored directly in the valueOffset field
                    mpEntryOffset = UInt32(currentOffset + 8) // Point to the valueOffset field itself
                } else {
                    // Data is stored at the offset pointed by valueOffset
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

private func parseMPEntries(_ data: Data, entryOffset: Int, numberOfImages: Int, byteOrder: ByteOrder, mpfOffset: UInt32) -> [ThumbnailEntry] {
    var thumbnails: [ThumbnailEntry] = []

    logger.debug("Parsing \(numberOfImages) MP entries at offset \(entryOffset)")

    // Parse all MP entries first
    var mpEntries: [MPImageEntry] = []
    var tempOffset = entryOffset

    for i in 0 ..< numberOfImages {
        guard tempOffset + 16 <= data.count else { break }

        let imageAttributes = readUInt32(data, offset: tempOffset, byteOrder: byteOrder)
        let imageSize = readUInt32(data, offset: tempOffset + 4, byteOrder: byteOrder)
        let imageOffset = readUInt32(data, offset: tempOffset + 8, byteOrder: byteOrder)
        let dependent1 = readUInt16(data, offset: tempOffset + 12, byteOrder: byteOrder)
        let dependent2 = readUInt16(data, offset: tempOffset + 14, byteOrder: byteOrder)

        // Extract flags, format, and type from imageAttributes
        let flags = (imageAttributes & 0xF800_0000) >> 27
        let format = (imageAttributes & 0x0700_0000) >> 24
        let type = imageAttributes & 0x00FF_FFFF

        logger.debug("MP Entry \(i): flags=0x\(String(flags, radix: 16)), format=\(format), type=0x\(String(type, radix: 16)), size=\(imageSize), offset=\(imageOffset)")

        let entry = MPImageEntry(
            flags: flags,
            format: format,
            type: type,
            length: imageSize,
            start: imageOffset,
            dependent1: dependent1,
            dependent2: dependent2
        )
        mpEntries.append(entry)
        tempOffset += 16
    }

    // Process entries to create thumbnails
    for entry in mpEntries {
        // Skip invalid entries
        guard entry.length > 0, entry.length < 50_000_000 else { continue }

        // Determine image type based on MPImageType
        let entryType: String
        let isPreview: Bool

        switch entry.type {
        case 0x010001: // Large Thumbnail (VGA equivalent)
            entryType = "thumbnail"
            isPreview = true
        case 0x010002: // Large Thumbnail (full HD equivalent)
            entryType = "thumbnail"
            isPreview = true
        case 0x010003: // Large Thumbnail (4K equivalent)
            entryType = "thumbnail"
            isPreview = true
        case 0x010004: // Large Thumbnail (8K equivalent)
            entryType = "thumbnail"
            isPreview = true
        case 0x010005: // Large Thumbnail (16K equivalent)
            entryType = "thumbnail"
            isPreview = true
        case 0x020001: // Multi-frame Panorama
            entryType = "preview"
            isPreview = true
        case 0x020002: // Multi-frame Disparity
            entryType = "preview"
            isPreview = true
        case 0x020003: // Multi-angle
            entryType = "preview"
            isPreview = true
        case 0x030000: // Baseline MP Primary Image
            entryType = "primary"
            isPreview = false
        case 0x040000: // Original Preservation Image
            entryType = "preview"
            isPreview = true
        case 0x050000: // Gain Map Image
            entryType = "preview"
            isPreview = true
        default:
            // Check if it's a large thumbnail type (0x01xxxx)
            if (entry.type & 0xFF0000) == 0x010000 {
                entryType = "thumbnail"
                isPreview = true
            } else {
                entryType = "preview"
                isPreview = true
            }
        }

        // Only extract preview/thumbnail images, skip primary image
        guard isPreview else { continue }

        // Calculate absolute offset
        if entry.start == 0 {
            // Offset 0 means this is the primary image at the start of the file
            // For thumbnails, this shouldn't happen, but handle it gracefully
            continue
        }
        // MPF offsets are relative to the start of the APP2 segment
        let absoluteOffset = entry.start + mpfOffset + 4

        let thumbnailEntry = ThumbnailEntry(
            offset: absoluteOffset,
            length: entry.length,
            type: entryType,
            width: nil, // MPF doesn't provide dimensions in header
            height: nil
        )
        thumbnails.append(thumbnailEntry)
        logger.debug("Found MPF \(entryType): offset=\(absoluteOffset), size=\(entry.length), type=0x\(String(entry.type, radix: 16))")
    }

    return thumbnails
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
