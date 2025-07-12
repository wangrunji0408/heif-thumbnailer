import CoreGraphics
import Foundation
import ImageIO
import Logging
import UniformTypeIdentifiers

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

private let logger = Logger(label: "com.hdremote.JpegThumbnailer")

// MARK: - JpegReader Implementation

public class JpegReader: ImageReader {
    private let reader: Reader
    private var thumbnailEntries: [ThumbnailEntry]?
    private var metadata: Metadata?

    public required init(readAt: @escaping (UInt64, UInt32) async throws -> Data) {
        reader = Reader(readAt: readAt)
    }

    public func getThumbnailList() async throws -> [ThumbnailInfo] {
        if thumbnailEntries == nil {
            try await loadMetadata()
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
            try await loadMetadata()
        }

        guard let entries = thumbnailEntries, index < entries.count else {
            throw ImageReaderError.indexOutOfBounds
        }

        let entry = entries[index]
        return try await reader.readAt(offset: UInt64(entry.offset), length: entry.length)
    }

    public func getMetadata() async throws -> Metadata {
        if metadata == nil {
            try await loadMetadata()
        }
        guard let metadata = metadata else {
            throw ImageReaderError.invalidData
        }
        return metadata
    }

    private func loadMetadata() async throws {
        // Read JPEG header and find EXIF data
        try await reader.prefetch(offset: 0, length: 16384)

        // Validate JPEG format
        guard try await reader.readAt(offset: 0, length: 2) == Data([0xFF, 0xD8]) else {
            throw ImageReaderError.invalidData
        }

        // Extract main image dimensions
        let mainImageDimensions = try await extractMainImageDimensions()

        // Find EXIF data and parse thumbnails
        var entries: [ThumbnailEntry] = []
        if let (exifOffset, exifLength) = try await extractExifData() {
            try await parseExifForThumbnails(exifOffset: exifOffset, exifLength: exifLength, entries: &entries)
        }

        // Look for MPF thumbnails
        let mpfEntries = try await extractMPFThumbnails()
        entries.append(contentsOf: mpfEntries)

        thumbnailEntries = entries
        metadata = Metadata(width: mainImageDimensions.width, height: mainImageDimensions.height)
    }

    private func extractMainImageDimensions() async throws -> (width: UInt32, height: UInt32) {
        var offset: UInt64 = 2 // Skip JPEG SOI marker

        // Search for SOF marker (0xFFC0, 0xFFC1, 0xFFC2, etc.)
        // Increase search range for complex JPEG files
        while offset < 1_048_576 { // 1MB search range
            try await reader.prefetch(offset: offset, length: 4)
            let marker = try await reader.readUInt16(offset: offset)
            guard (marker & 0xFF00) == 0xFF00 else { break }

            let markerType = UInt8(marker & 0xFF)
            let segmentLength = try await reader.readUInt16(offset: offset + 2)

            // Check if this is a SOF marker (0xC0-0xCF, but not 0xC4, 0xC8, 0xCC)
            if (markerType >= 0xC0 && markerType <= 0xCF) &&
                markerType != 0xC4 && markerType != 0xC8 && markerType != 0xCC
            {
                // Read SOF segment
                try await reader.prefetch(offset: offset + 4, length: UInt32(segmentLength))
                if segmentLength >= 6 {
                    let height = try await reader.readUInt16(offset: offset + 5)
                    let width = try await reader.readUInt16(offset: offset + 7)
                    logger.debug("Found SOF marker at offset \(offset), width=\(width), height=\(height)")
                    return (UInt32(width), UInt32(height))
                }
            }

            if segmentLength < 2 { break }
            offset += 2 + UInt64(segmentLength)
        }

        throw ImageReaderError.invalidData
    }

    private func extractExifData() async throws -> (UInt64, UInt32)? {
        var offset: UInt64 = 2 // Skip JPEG SOI marker

        // Search for EXIF segment (APP1 with EXIF identifier)
        while offset < 65536 {
            let marker = try await reader.readUInt16(offset: offset)
            guard (marker & 0xFF00) == 0xFF00 else { break }

            let markerType = UInt8(marker & 0xFF)
            let segmentLength = try await reader.readUInt16(offset: offset + 2)

            if markerType == 0xE1 { // APP1 segment
                let segmentData = try await reader.readAt(offset: offset + 4, length: UInt32(segmentLength))
                if segmentData.starts(with: "Exif".data(using: .ascii)!) {
                    logger.debug("Found EXIF data at offset \(offset + 4)")
                    let exifOffset = offset + 10 // offset + 4 (segment header) + 6 (Exif\0\0)
                    let exifLength = UInt32(segmentLength - 6) // Skip "Exif\0\0"
                    return (exifOffset, exifLength)
                }
            }

            if segmentLength < 2 { break }
            offset += 2 + UInt64(segmentLength)
        }

        return nil
    }

    private func parseExifForThumbnails(exifOffset: UInt64, exifLength: UInt32, entries: inout [ThumbnailEntry]) async throws {
        guard exifLength >= 8 else { return }

        // Prefetch EXIF data for dense reading
        try await reader.prefetch(offset: exifOffset, length: exifLength)

        // Parse TIFF header
        let tiffHeader = try await parseTiffHeader(exifOffset: exifOffset)

        // Parse IFD0 (main image)
        if let ifd1Offset = try await parseIFD(
            exifOffset: exifOffset,
            ifdOffset: UInt64(tiffHeader.ifdOffset),
            entries: &entries,
            isThumbnail: false,
            byteOrder: tiffHeader.byteOrder
        ) {
            // Parse IFD1 (thumbnail)
            if ifd1Offset > 0 {
                _ = try await parseIFD(
                    exifOffset: exifOffset,
                    ifdOffset: UInt64(ifd1Offset),
                    entries: &entries,
                    isThumbnail: true,
                    byteOrder: tiffHeader.byteOrder
                )
            }
        }
    }

    private func parseTiffHeader(exifOffset: UInt64) async throws -> (byteOrder: ByteOrder, ifdOffset: UInt32) {
        // Check byte order
        let byteOrderData = try await reader.readAt(offset: exifOffset, length: 2)
        let byteOrder: ByteOrder
        if byteOrderData[0] == 0x49, byteOrderData[1] == 0x49 { // "II" - Intel (little endian)
            byteOrder = .littleEndian
        } else if byteOrderData[0] == 0x4D, byteOrderData[1] == 0x4D { // "MM" - Motorola (big endian)
            byteOrder = .bigEndian
        } else {
            throw ImageReaderError.invalidData
        }

        reader.setByteOrder(byteOrder)

        // Check magic number (42)
        let magic = try await reader.readUInt16(offset: exifOffset + 2)
        guard magic == 42 else { throw ImageReaderError.invalidData }

        // Read IFD offset
        let ifdOffset = try await reader.readUInt32(offset: exifOffset + 4)

        return (byteOrder, ifdOffset)
    }

    private func parseIFD(
        exifOffset: UInt64,
        ifdOffset: UInt64,
        entries: inout [ThumbnailEntry],
        isThumbnail: Bool,
        byteOrder _: ByteOrder
    ) async throws -> UInt32? {
        let absoluteIfdOffset = exifOffset + ifdOffset

        let entryCount = try await reader.readUInt16(offset: absoluteIfdOffset)
        let entriesDataLength = UInt32(entryCount * 12 + 4) // 12 bytes per entry + 4 bytes for next IFD offset

        // Prefetch all IFD entries for dense reading
        try await reader.prefetch(offset: absoluteIfdOffset, length: entriesDataLength)

        var currentOffset = absoluteIfdOffset + 2

        var thumbnailOffset: UInt32?
        var thumbnailLength: UInt32?
        var thumbnailWidth: UInt32?
        var thumbnailHeight: UInt32?

        logger.debug("Parsing IFD at offset \(ifdOffset), isThumbnail: \(isThumbnail), entryCount: \(entryCount)")

        // Parse directory entries
        for _ in 0 ..< entryCount {
            let tag = try await reader.readUInt16(offset: currentOffset)
            let _ = try await reader.readUInt16(offset: currentOffset + 2) // type
            let _ = try await reader.readUInt32(offset: currentOffset + 4) // count
            let valueOffset = try await reader.readUInt32(offset: currentOffset + 8)

            if isThumbnail {
                switch tag {
                case 0x0201: // JPEGInterchangeFormat (thumbnail offset)
                    thumbnailOffset = valueOffset
                case 0x0202: // JPEGInterchangeFormatLength (thumbnail length)
                    thumbnailLength = valueOffset
                case 0x0100: // ImageWidth
                    thumbnailWidth = valueOffset
                case 0x0101: // ImageLength (Height)
                    thumbnailHeight = valueOffset
                default:
                    break
                }
            }

            currentOffset += 12
        }

        // If this is a thumbnail IFD and we found both offset and length
        if isThumbnail, let relativeOffset = thumbnailOffset, let length = thumbnailLength {
            // Convert relative offset to absolute offset
            let absoluteOffset = UInt32(exifOffset) + relativeOffset
            let entry = ThumbnailEntry(
                offset: absoluteOffset,
                length: length,
                type: "thumbnail",
                width: thumbnailWidth,
                height: thumbnailHeight
            )
            entries.append(entry)
            logger.debug("Found thumbnail: relativeOffset=\(relativeOffset), absoluteOffset=\(absoluteOffset), length=\(length), width=\(thumbnailWidth ?? 0), height=\(thumbnailHeight ?? 0)")
        }

        // Read next IFD offset
        let nextIFDOffset = try await reader.readUInt32(offset: currentOffset)

        return nextIFDOffset > 0 ? nextIFDOffset : nil
    }

    private func extractMPFThumbnails() async throws -> [ThumbnailEntry] {
        var offset: UInt64 = 2 // Skip JPEG SOI marker

        // Search for APP2 segments that contain MPF data
        while true {
            try await reader.prefetch(offset: offset, length: 256)
            let marker = try await reader.readUInt16(offset: offset)
            guard (marker & 0xFF00) == 0xFF00 else { break }

            let markerType = UInt8(marker & 0xFF)
            let segmentLength = try await reader.readUInt16(offset: offset + 2)

            if markerType == 0xE2 { // APP2 segment
                let segmentData = try await reader.readAt(offset: offset + 4, length: UInt32(segmentLength))
                if segmentData.starts(with: "MPF\0".data(using: .ascii)!) ||
                    segmentData.starts(with: "MPF ".data(using: .ascii)!)
                {
                    logger.debug("Found MPF data in APP2 segment at offset \(offset + 4), segment size: \(segmentData.count)")
                    let mpfOffset = offset + 4
                    let mpfEntries = try await parseMPFData(mpfOffset: mpfOffset, mpfLength: UInt32(segmentLength))
                    logger.debug("MPF parsing returned \(mpfEntries.count) entries")
                    return mpfEntries
                }
            }

            if segmentLength < 2 { break }
            offset += 2 + UInt64(segmentLength)
        }

        return []
    }

    private func parseMPFData(mpfOffset: UInt64, mpfLength: UInt32) async throws -> [ThumbnailEntry] {
        var thumbnails: [ThumbnailEntry] = []
        guard mpfLength >= 12 else {
            logger.debug("MPF data too small: \(mpfLength) bytes")
            return thumbnails
        }

        // Prefetch MPF data for dense reading
        try await reader.prefetch(offset: mpfOffset, length: mpfLength)

        // Parse MPF header
        let tiffDataOffset = mpfOffset + 4 // Skip "MPF\0" or "MPF "

        logger.debug("MPF data size: \(mpfLength) bytes, TIFF data starts at offset \(tiffDataOffset)")

        // Parse TIFF header within MPF
        let tiffHeader = try await parseTiffHeader(exifOffset: tiffDataOffset)

        logger.debug("MPF TIFF header parsed, byte order: \(tiffHeader.byteOrder), IFD offset: \(tiffHeader.ifdOffset)")

        // Parse MP Index IFD
        let mpIndexIFDOffset = tiffDataOffset + UInt64(tiffHeader.ifdOffset)

        let entryCount = try await reader.readUInt16(offset: mpIndexIFDOffset)
        let entriesDataLength = UInt32(entryCount * 12 + 4) // 12 bytes per entry + 4 bytes for next IFD offset

        // Prefetch all IFD entries for dense reading
        try await reader.prefetch(offset: mpIndexIFDOffset, length: entriesDataLength)

        var currentOffset = mpIndexIFDOffset + 2

        logger.debug("MPF Index IFD at offset \(mpIndexIFDOffset) has \(entryCount) entries")

        var numberOfImages: UInt32 = 0
        var mpEntryOffset: UInt64 = 0

        // Parse MP Index IFD entries
        for _ in 0 ..< entryCount {
            let tag = try await reader.readUInt16(offset: currentOffset)
            let type = try await reader.readUInt16(offset: currentOffset + 2)
            let count = try await reader.readUInt32(offset: currentOffset + 4)
            let valueOffset = try await reader.readUInt32(offset: currentOffset + 8)

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
                        mpEntryOffset = currentOffset + 8 // Point to the valueOffset field itself
                    } else {
                        // Data is stored at the offset pointed by valueOffset
                        // The offset is relative to the start of the TIFF header
                        mpEntryOffset = tiffDataOffset + UInt64(valueOffset)
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
            let mpEntries = try await parseMPEntries(
                entryOffset: mpEntryOffset,
                numberOfImages: Int(numberOfImages),
                mpfOffset: mpfOffset
            )
            thumbnails.append(contentsOf: mpEntries)
        }

        return thumbnails
    }

    private func parseMPEntries(
        entryOffset: UInt64,
        numberOfImages: Int,
        mpfOffset: UInt64
    ) async throws -> [ThumbnailEntry] {
        var thumbnails: [ThumbnailEntry] = []

        logger.debug("Parsing \(numberOfImages) MP entries at offset \(entryOffset)")

        // Prefetch all MP entries for dense reading (16 bytes per entry)
        let entriesDataLength = UInt32(numberOfImages * 16)
        try await reader.prefetch(offset: entryOffset, length: entriesDataLength)

        // Parse all MP entries
        var tempOffset = entryOffset

        for i in 0 ..< numberOfImages {
            let imageAttributes = try await reader.readUInt32(offset: tempOffset)
            let imageSize = try await reader.readUInt32(offset: tempOffset + 4)
            let imageOffset = try await reader.readUInt32(offset: tempOffset + 8)
            let _ = try await reader.readUInt16(offset: tempOffset + 12) // dependent1
            let _ = try await reader.readUInt16(offset: tempOffset + 14) // dependent2

            // Extract flags, format, and type from imageAttributes
            let flags = (imageAttributes & 0xF800_0000) >> 27
            let format = (imageAttributes & 0x0700_0000) >> 24
            let type = imageAttributes & 0x00FF_FFFF

            logger.debug("MP Entry \(i): flags=0x\(String(flags, radix: 16)), format=\(format), type=0x\(String(type, radix: 16)), size=\(imageSize), offset=\(imageOffset)")

            // Process entry to create thumbnail
            // Skip invalid entries
            guard imageSize > 0, imageSize < 50_000_000 else { continue }

            // Determine if this is a preview/thumbnail image
            let isPreview: Bool
            switch type {
            case 0x010001 ... 0x010005: // Large Thumbnails
                isPreview = true
            case 0x020001 ... 0x020003: // Multi-frame images
                isPreview = true
            case 0x040000: // Original Preservation Image
                isPreview = true
            case 0x050000: // Gain Map Image
                isPreview = true
            case 0x030000: // Baseline MP Primary Image
                isPreview = false
            default:
                // Check if it's a large thumbnail type (0x01xxxx)
                isPreview = (type & 0xFF0000) == 0x010000
            }

            // Only extract preview/thumbnail images, skip primary image
            guard isPreview else { continue }

            // Calculate absolute offset
            if imageOffset == 0 {
                // Offset 0 means this is the primary image at the start of the file
                // For thumbnails, this shouldn't happen, but handle it gracefully
                continue
            }

            // MPF offsets are relative to the start of the APP2 segment
            let absoluteOffset = UInt32(mpfOffset) + 4 + imageOffset

            let thumbnailEntry = ThumbnailEntry(
                offset: absoluteOffset,
                length: imageSize,
                type: "mpf_thumbnail",
                width: nil, // MPF doesn't provide dimensions in header
                height: nil
            )
            thumbnails.append(thumbnailEntry)
            logger.debug("Found MPF thumbnail: offset=\(absoluteOffset), size=\(imageSize), type=0x\(String(type, radix: 16))")

            tempOffset += 16
        }

        return thumbnails
    }
}

// MARK: - Internal Types

private struct ThumbnailEntry {
    let offset: UInt32
    let length: UInt32
    let type: String
    let width: UInt32?
    let height: UInt32?
}

// MARK: - Utility Functions

/// Apply orientation correction to thumbnail data and return corrected Data
/// - Parameters:
///   - thumbnailData: Original thumbnail data
///   - rotation: Rotation degrees (0, 90, 180, 270)
/// - Returns: Corrected thumbnail data, or nil if correction fails
func applyOrientationCorrection(to thumbnailData: Data, rotation: Int, flip: Bool) -> Data? {
    // If no rotation needed, return original data
    guard rotation != 0 || flip else { return thumbnailData }

    // Create CGImage from thumbnail data
    guard let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else {
        logger.error("Failed to create CGImage from thumbnail data")
        return nil
    }

    // Apply rotation
    let rotatedImage = rotateCGImage(cgImage, by: rotation, flip: flip)

    // Convert back to JPEG data
    guard let mutableData = CFDataCreateMutable(nil, 0),
          let destination = CGImageDestinationCreateWithData(mutableData, UTType.jpeg.identifier as CFString, 1, nil)
    else {
        logger.error("Failed to create image destination")
        return nil
    }

    // Set JPEG compression quality
    let options: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.9,
    ]

    CGImageDestinationAddImage(destination, rotatedImage, options as CFDictionary)

    guard CGImageDestinationFinalize(destination) else {
        logger.error("Failed to finalize image destination")
        return nil
    }

    logger.debug("Successfully applied orientation correction")
    return mutableData as Data
}

private func rotateCGImage(_ image: CGImage, by degrees: Int, flip: Bool) -> CGImage {
    let normalizedDegrees = ((degrees % 360) + 360) % 360
    guard normalizedDegrees != 0 || flip else { return image }

    let (width, height) = (image.width, image.height)
    let (newWidth, newHeight) =
        (normalizedDegrees == 90 || normalizedDegrees == 270) ? (height, width) : (width, height)

    guard let colorSpace = image.colorSpace,
          let context = CGContext(
              data: nil, width: newWidth, height: newHeight,
              bitsPerComponent: image.bitsPerComponent, bytesPerRow: 0,
              space: colorSpace, bitmapInfo: image.bitmapInfo.rawValue
          )
    else {
        return image
    }

    context.translateBy(x: CGFloat(newWidth) / 2, y: CGFloat(newHeight) / 2)
    if flip {
        context.scaleBy(x: -1, y: 1)
    }
    context.rotate(by: -CGFloat(normalizedDegrees) * .pi / 180)
    context.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    return context.makeImage() ?? image
}

private func orientationToRotation(_ orientation: UInt16) -> (Int, Bool) {
    switch orientation {
    case 1: return (0, false) // Normal
    case 2: return (0, true) // Mirror horizontal (no rotation, just flip)
    case 3: return (180, false) // Rotate 180°
    case 4: return (180, true) // Mirror vertical (180° + flip)
    case 5: return (270, true) // Mirror horizontal and rotate 270° CW
    case 6: return (90, false) // Rotate 90° CW
    case 7: return (90, true) // Mirror horizontal and rotate 90° CW
    case 8: return (270, false) // Rotate 270° CW
    default: return (0, false) // Unknown orientation, default to normal
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
