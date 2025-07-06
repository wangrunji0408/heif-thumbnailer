import CoreGraphics
import Foundation
import ImageIO
import Logging
import UniformTypeIdentifiers

#if canImport(UIKit)
    import UIKit

    public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
    import AppKit

    public typealias PlatformImage = NSImage
#endif

private let logger = Logger(label: "com.hdremote.HeifThumbnailer")

// MARK: - Public Types

public struct Thumbnail {
    public let data: Data
    public let rotation: Int
    public let type: String
    public let width: UInt32
    public let height: UInt32
}

public struct ImageSize {
    public let width: UInt32
    public let height: UInt32

    var shortSide: UInt32 {
        min(width, height)
    }
}

// MARK: - Internal Types

struct ThumbnailInfo {
    let itemId: UInt32
    let offset: UInt32
    let size: UInt32
    let rotation: Int?
    let imageSize: ImageSize?
    let type: String
    let properties: [ItemProperty]
}

struct ItemProperty {
    let propertyIndex: UInt32
    let propertyType: String
    let rotation: Int?
    let imageSize: ImageSize?
    let rawData: Data
}

private struct ItemInfo {
    let itemId: UInt32
    let itemType: String
    let itemName: String?
}

private struct ItemLocation {
    let itemId: UInt32
    let offset: UInt32
    let length: UInt32
}

private struct ItemPropertyAssociation {
    let itemId: UInt32
    let propertyIndices: [UInt32]
}

// MARK: - Public API

/// Efficiently read thumbnail from a HEIC file with minimal read operations
/// - Parameters:
///   - readAt: Async function to read data at specific offset and length
///   - minShortSide: Minimum short side length in pixels. Returns the smallest thumbnail that meets this requirement. If nil, returns the first available thumbnail.
/// - Returns: Thumbnail data with metadata, or nil if extraction fails
public func readHeifThumbnail(
    readAt: @escaping (UInt64, UInt32) async throws -> Data,
    minShortSide: UInt32? = nil
) async throws -> Thumbnail? {
    // Step 1: Validate HEIC format and get meta data
    guard let metaData = try await readMetaBox(readAt: readAt) else {
        logger.error("Meta box not found")
        return nil
    }

    // Step 2: Parse meta box
    let thumbnailInfos = parseMetaBox(data: metaData)

    guard !thumbnailInfos.isEmpty else {
        logger.error("No thumbnails found in meta box")
        return nil
    }

    // Step 3: Find suitable thumbnail
    guard let thumbnailInfo = findSuitableThumbnail(thumbnailInfos, minShortSide: minShortSide)
    else {
        logger.error("No thumbnail meets the minShortSide requirement")
        return nil
    }

    // Step 4: Read and process thumbnail data
    let thumbnailData = try await readAt(UInt64(thumbnailInfo.offset), thumbnailInfo.size)
    return try await createThumbnail(from: thumbnailInfo, data: thumbnailData)
}

/// Convenience function to extract thumbnail as platform image
public func readHeifThumbnailAsImage(
    readAt: @escaping (UInt64, UInt32) async throws -> Data,
    minShortSide: UInt32? = nil
) async throws -> PlatformImage? {
    guard let thumbnail = try await readHeifThumbnail(readAt: readAt, minShortSide: minShortSide)
    else {
        return nil
    }
    return createImageFromThumbnailData(thumbnail.data, rotation: thumbnail.rotation)
}

// MARK: - HEIC Format Validation

private func readMetaBox(readAt: @escaping (UInt64, UInt32) async throws -> Data) async throws
    -> Data?
{
    // Read initial header
    let data = try await readAt(0, 2048)
    guard data.count >= 8 else { return nil }

    var offset: UInt64 = 0

    // Validate ftyp box
    guard let (ftypSize, ftypType) = parseBoxHeader(data: data, offset: &offset),
          ftypType == "ftyp"
    else {
        logger.error("Invalid HEIC file: missing ftyp box")
        return nil
    }

    // Verify HEIC brand
    if ftypSize >= 12, offset + 4 <= data.count {
        let brandData = data.subdata(in: Int(offset) ..< Int(offset + 4))
        let brand = String(data: brandData, encoding: .ascii) ?? ""
        guard brand.hasPrefix("hei") else {
            logger.error("Not a HEIC file, brand: \(brand)")
            return nil
        }
        logger.debug("Detected HEIC file, brand: \(brand)")
    }

    offset = UInt64(ftypSize)

    // Search in current data
    while offset + 8 < data.count {
        let savedOffset = offset
        guard let (boxSize, boxType) = parseBoxHeader(data: data, offset: &offset) else { break }

        if boxType == "meta" {
            logger.debug("Found meta box: offset=\(savedOffset), size=\(boxSize)")
            if savedOffset + UInt64(boxSize) <= data.count {
                return data.subdata(in: Int(savedOffset) ..< Int(savedOffset + UInt64(boxSize)))
            } else {
                return try await readAt(savedOffset, boxSize)
            }
        }

        if boxSize > 8, savedOffset + UInt64(boxSize) <= data.count {
            offset = savedOffset + UInt64(boxSize)
        } else {
            break
        }
    }

    return nil
}

// MARK: - Meta Box Parsing

private func parseMetaBox(data: Data) -> [ThumbnailInfo] {
    var offset: UInt64 = 12 // Skip meta box header + version/flags

    var items: [ItemInfo] = []
    var locations: [ItemLocation] = []
    var primaryItemId: UInt32 = 0
    var thumbnailReferences: [(from: UInt32, to: [UInt32])] = []
    var properties: [ItemProperty] = []
    var propertyAssociations: [ItemPropertyAssociation] = []

    logger.debug("Parsing meta box, data size: \(data.count) bytes")

    // Parse all sub-boxes
    while offset + 8 < data.count {
        let savedOffset = offset
        guard let (boxSize, boxType) = parseBoxHeader(data: data, offset: &offset) else { break }

        let boxData = data.subdata(
            in: Int(savedOffset + 8) ..< min(Int(savedOffset + UInt64(boxSize)), data.count))

        switch boxType {
        case "pitm":
            primaryItemId = parsePrimaryItem(data: boxData) ?? 0
            logger.debug("Primary item ID: \(primaryItemId)")

        case "iinf":
            items = parseItemInfo(data: boxData)
            logger.debug("Found \(items.count) items")

        case "iloc":
            locations = parseItemLocation(data: boxData)
            logger.debug("Found \(locations.count) locations")

        case "iref":
            thumbnailReferences = parseItemReference(data: boxData)
            logger.debug("Found \(thumbnailReferences.count) references")

        case "iprp":
            (properties, propertyAssociations) = parseItemProperties(data: boxData)
            logger.debug(
                "Found \(properties.count) properties, \(propertyAssociations.count) associations")

        default:
            logger.debug("Skipping box type: \(boxType)")
        }

        offset = boxSize > 8 ? savedOffset + UInt64(boxSize) : UInt64(data.count)
    }

    return buildThumbnailInfos(
        items: items,
        locations: locations,
        primaryItemId: primaryItemId,
        thumbnailReferences: thumbnailReferences,
        properties: properties,
        propertyAssociations: propertyAssociations
    )
}

private func buildThumbnailInfos(
    items: [ItemInfo],
    locations: [ItemLocation],
    primaryItemId: UInt32,
    thumbnailReferences: [(from: UInt32, to: [UInt32])],
    properties: [ItemProperty],
    propertyAssociations: [ItemPropertyAssociation]
) -> [ThumbnailInfo] {
    var thumbnailCandidates: [ThumbnailInfo] = []

    for (thumbnailId, masterIds) in thumbnailReferences {
        guard masterIds.contains(primaryItemId),
              let item = items.first(where: { $0.itemId == thumbnailId }),
              let location = locations.first(where: { $0.itemId == thumbnailId })
        else {
            continue
        }

        let (rotation, imageSize, associatedProperties) = extractItemProperties(
            itemId: thumbnailId,
            properties: properties,
            propertyAssociations: propertyAssociations
        )

        let thumbnail = ThumbnailInfo(
            itemId: thumbnailId,
            offset: location.offset,
            size: location.length,
            rotation: rotation,
            imageSize: imageSize,
            type: item.itemType,
            properties: associatedProperties
        )

        thumbnailCandidates.append(thumbnail)
        logger.debug(
            "Found thumbnail: itemId=\(thumbnailId), type=\(item.itemType), size=\(imageSize?.width ?? 0)x\(imageSize?.height ?? 0)"
        )
    }

    // Sort by size (smallest first)
    return thumbnailCandidates.sorted {
        ($0.imageSize?.shortSide ?? UInt32.max) < ($1.imageSize?.shortSide ?? UInt32.max)
    }
}

private func extractItemProperties(
    itemId: UInt32,
    properties: [ItemProperty],
    propertyAssociations: [ItemPropertyAssociation]
) -> (rotation: Int?, imageSize: ImageSize?, properties: [ItemProperty]) {
    guard let association = propertyAssociations.first(where: { $0.itemId == itemId }) else {
        return (nil, nil, [])
    }

    var rotation: Int?
    var imageSize: ImageSize?
    var associatedProperties: [ItemProperty] = []

    for propertyIndex in association.propertyIndices {
        guard let property = properties.first(where: { $0.propertyIndex == propertyIndex }) else {
            continue
        }

        associatedProperties.append(property)

        switch property.propertyType {
        case "irot":
            rotation = property.rotation
        case "ispe":
            imageSize = property.imageSize
        default:
            break
        }
    }

    return (rotation, imageSize, associatedProperties)
}

// MARK: - Box Parsing Utilities

private func parseBoxHeader(data: Data, offset: inout UInt64) -> (UInt32, String)? {
    guard offset + 8 <= data.count else { return nil }

    let size = data.subdata(in: Int(offset) ..< Int(offset + 4))
        .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    let type =
        String(data: data.subdata(in: Int(offset + 4) ..< Int(offset + 8)), encoding: .ascii) ?? ""

    offset += 8
    return (size, type)
}

private func parsePrimaryItem(data: Data) -> UInt32? {
    guard data.count >= 6 else { return nil }
    return data.subdata(in: 4 ..< 6)
        .withUnsafeBytes { UInt32($0.load(as: UInt16.self).bigEndian) }
}

private func parseItemInfo(data: Data) -> [ItemInfo] {
    var items: [ItemInfo] = []
    var offset = 4 // Skip version/flags

    guard offset + 2 < data.count else { return items }

    let entryCount = data.subdata(in: offset ..< offset + 2)
        .withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
    offset += 2

    for _ in 0 ..< entryCount {
        guard offset + 8 < data.count else { break }

        let savedOffset = offset
        var localOffset = UInt64(offset)
        guard let (infeSize, infeType) = parseBoxHeader(data: data, offset: &localOffset),
              infeType == "infe", infeSize > 8
        else {
            break
        }

        let infeData = data.subdata(
            in: Int(localOffset) ..< min(Int(savedOffset + Int(infeSize)), data.count))
        if let item = parseInfeBox(data: infeData) {
            items.append(item)
        }

        offset = savedOffset + Int(infeSize)
    }

    return items
}

private func parseInfeBox(data: Data) -> ItemInfo? {
    guard data.count >= 8 else { return nil }

    let itemId = data.subdata(in: 4 ..< 6)
        .withUnsafeBytes { UInt32($0.load(as: UInt16.self).bigEndian) }

    guard data.count >= 12 else { return nil }
    let itemType = String(data: data.subdata(in: 8 ..< 12), encoding: .ascii) ?? ""

    return ItemInfo(itemId: itemId, itemType: itemType, itemName: nil)
}

private func parseItemLocation(data: Data) -> [ItemLocation] {
    var locations: [ItemLocation] = []
    var offset = 4 // Skip version/flags

    guard data.count > 0, offset + 2 < data.count else { return locations }

    let version = data[0]
    let values4 = data.subdata(in: offset ..< offset + 2)
        .withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }

    let offsetSize = (values4 >> 12) & 0xF
    let lengthSize = (values4 >> 8) & 0xF
    let baseOffsetSize = (values4 >> 4) & 0xF
    let indexSize = (version >= 1) ? (values4 & 0xF) : 0

    offset += 2

    // Read item count
    let itemCount: UInt32
    if version < 2 {
        guard offset + 2 <= data.count else { return locations }
        itemCount = UInt32(
            data.subdata(in: offset ..< offset + 2)
                .withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
        offset += 2
    } else {
        guard offset + 4 <= data.count else { return locations }
        itemCount = data.subdata(in: offset ..< offset + 4)
            .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        offset += 4
    }

    for _ in 0 ..< itemCount {
        guard
            let location = parseItemLocationEntry(
                data: data,
                offset: &offset,
                version: version,
                offsetSize: offsetSize,
                lengthSize: lengthSize,
                baseOffsetSize: baseOffsetSize,
                indexSize: indexSize
            )
        else { break }

        locations.append(location)
    }

    return locations
}

private func parseItemLocationEntry(
    data: Data,
    offset: inout Int,
    version: UInt8,
    offsetSize: UInt16,
    lengthSize: UInt16,
    baseOffsetSize: UInt16,
    indexSize: UInt16
) -> ItemLocation? {
    // Read item ID
    let itemId: UInt32
    if version < 2 {
        guard offset + 2 <= data.count else { return nil }
        itemId = UInt32(
            data.subdata(in: offset ..< offset + 2)
                .withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
        offset += 2
    } else {
        guard offset + 4 <= data.count else { return nil }
        itemId = data.subdata(in: offset ..< offset + 4)
            .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        offset += 4
    }

    // Skip construction_method, data_reference_index, base_offset
    let skipSize = (version >= 1 ? 2 : 0) + 2 + Int(baseOffsetSize)
    guard offset + skipSize <= data.count else { return nil }
    offset += skipSize

    // Read extent count
    guard offset + 2 <= data.count else { return nil }
    let extentCount = data.subdata(in: offset ..< offset + 2)
        .withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
    offset += 2

    guard extentCount > 0 else { return nil }

    // Read first extent only
    let extentSize = Int(indexSize + offsetSize + lengthSize)
    guard offset + extentSize <= data.count else { return nil }

    offset += Int(indexSize) // Skip extent_index

    // Read extent_offset
    let itemOffset: UInt32
    if offsetSize == 4 {
        itemOffset = data.subdata(in: offset ..< offset + 4)
            .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        offset += 4
    } else if offsetSize == 8 {
        let offset64 = data.subdata(in: offset ..< offset + 8)
            .withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        itemOffset = UInt32(offset64 & 0xFFFF_FFFF)
        offset += 8
    } else {
        return nil
    }

    // Read extent_length
    let itemLength: UInt32
    if lengthSize == 4 {
        itemLength = data.subdata(in: offset ..< offset + 4)
            .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        offset += 4
    } else if lengthSize == 8 {
        let length64 = data.subdata(in: offset ..< offset + 8)
            .withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        itemLength = UInt32(length64 & 0xFFFF_FFFF)
        offset += 8
    } else {
        return nil
    }

    // Skip remaining extents
    let remainingExtents = Int(extentCount) - 1
    if remainingExtents > 0 {
        offset += remainingExtents * extentSize
    }

    return ItemLocation(itemId: itemId, offset: itemOffset, length: itemLength)
}

private func parseItemReference(data: Data) -> [(from: UInt32, to: [UInt32])] {
    var references: [(from: UInt32, to: [UInt32])] = []
    var offset = 4 // Skip version/flags

    let version = data.count > 0 ? data[0] : 0
    let idSize = (version == 0) ? 2 : 4

    while offset + 8 < data.count {
        guard offset + 8 <= data.count else { break }

        let refBoxSize = data.subdata(in: offset ..< offset + 4)
            .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let refBoxType =
            String(data: data.subdata(in: offset + 4 ..< offset + 8), encoding: .ascii) ?? ""

        offset += 8

        if refBoxType == "thmb",
           let reference = parseThumbnailReference(data: data, offset: &offset, idSize: idSize)
        {
            references.append(reference)
        } else if refBoxSize > 8 {
            offset += Int(refBoxSize) - 8
        } else {
            break
        }
    }

    return references
}

private func parseThumbnailReference(data: Data, offset: inout Int, idSize: Int) -> (
    from: UInt32, to: [UInt32]
)? {
    guard offset + idSize + 2 <= data.count else { return nil }

    // Read from_item_ID
    let fromItemId: UInt32 = if idSize == 2 {
        UInt32(
            data.subdata(in: offset ..< offset + 2)
                .withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
    } else {
        data.subdata(in: offset ..< offset + 4)
            .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }
    offset += idSize

    // Read reference count
    let refCount = data.subdata(in: offset ..< offset + 2)
        .withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
    offset += 2

    // Read to_item_IDs
    var toItemIds: [UInt32] = []
    for _ in 0 ..< refCount {
        guard offset + idSize <= data.count else { break }

        let toItemId: UInt32 = if idSize == 2 {
            UInt32(
                data.subdata(in: offset ..< offset + 2)
                    .withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
        } else {
            data.subdata(in: offset ..< offset + 4)
                .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        }
        toItemIds.append(toItemId)
        offset += idSize
    }

    return (from: fromItemId, to: toItemIds)
}

private func parseItemProperties(data: Data) -> ([ItemProperty], [ItemPropertyAssociation]) {
    var properties: [ItemProperty] = []
    var associations: [ItemPropertyAssociation] = []
    var offset = 0

    while offset + 8 < data.count {
        let savedOffset = offset
        var localOffset = UInt64(offset)
        guard let (boxSize, boxType) = parseBoxHeader(data: data, offset: &localOffset) else {
            break
        }

        let boxData = data.subdata(
            in: Int(localOffset) ..< min(Int(savedOffset + Int(boxSize)), data.count))

        switch boxType {
        case "ipco":
            properties = parseItemPropertyContainer(data: boxData)
        case "ipma":
            associations = parseItemPropertyAssociation(data: boxData)
        default:
            break
        }

        offset = savedOffset + Int(boxSize)
    }

    return (properties, associations)
}

private func parseItemPropertyContainer(data: Data) -> [ItemProperty] {
    var properties: [ItemProperty] = []
    var offset = 0
    var propertyIndex: UInt32 = 1

    while offset + 8 < data.count {
        let savedOffset = offset
        var localOffset = UInt64(offset)
        guard let (boxSize, boxType) = parseBoxHeader(data: data, offset: &localOffset) else {
            break
        }

        let boxData = data.subdata(
            in: Int(localOffset) ..< min(Int(savedOffset + Int(boxSize)), data.count))

        let rotation = (boxType == "irot") ? parseIrotBox(data: boxData) : nil
        let imageSize = (boxType == "ispe") ? parseIspeBox(data: boxData) : nil

        let property = ItemProperty(
            propertyIndex: propertyIndex,
            propertyType: boxType,
            rotation: rotation,
            imageSize: imageSize,
            rawData: boxData
        )
        properties.append(property)

        propertyIndex += 1
        offset = savedOffset + Int(boxSize)
    }

    return properties
}

private func parseIrotBox(data: Data) -> Int? {
    guard data.count >= 1 else { return nil }
    return Int(data[0] & 0x03) * 90
}

private func parseIspeBox(data: Data) -> ImageSize? {
    guard data.count >= 12 else { return nil }

    let width = data.subdata(in: 4 ..< 8)
        .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    let height = data.subdata(in: 8 ..< 12)
        .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

    return ImageSize(width: width, height: height)
}

private func parseItemPropertyAssociation(data: Data) -> [ItemPropertyAssociation] {
    var associations: [ItemPropertyAssociation] = []
    var offset = 4 // Skip version/flags

    guard offset + 4 < data.count else { return associations }

    let entryCount = data.subdata(in: offset ..< offset + 4)
        .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    offset += 4

    for _ in 0 ..< entryCount {
        guard offset + 3 < data.count else { break }

        let itemId = data.subdata(in: offset ..< offset + 2)
            .withUnsafeBytes { UInt32($0.load(as: UInt16.self).bigEndian) }
        offset += 2

        let associationCount = data[offset]
        offset += 1

        var propertyIndices: [UInt32] = []
        for _ in 0 ..< associationCount {
            guard offset < data.count else { break }
            let propertyIndex = UInt32(data[offset] & 0x7F)
            propertyIndices.append(propertyIndex)
            offset += 1
        }

        associations.append(
            ItemPropertyAssociation(itemId: itemId, propertyIndices: propertyIndices))
    }

    return associations
}

// MARK: - Thumbnail Processing

private func findSuitableThumbnail(_ thumbnails: [ThumbnailInfo], minShortSide: UInt32?)
    -> ThumbnailInfo?
{
    guard let minShortSide else { return thumbnails.first }

    return thumbnails.first { thumbnail in
        guard let imageSize = thumbnail.imageSize else { return true }
        return imageSize.shortSide >= minShortSide
    }
}

private func createThumbnail(from info: ThumbnailInfo, data: Data) async throws -> Thumbnail? {
    let rotation = info.rotation ?? 0
    let width = info.imageSize?.width ?? 0
    let height = info.imageSize?.height ?? 0

    switch info.type {
    case "jpeg":
        logger.debug("Processing JPEG thumbnail")
        return Thumbnail(data: data, rotation: rotation, type: "jpeg", width: width, height: height)

    case "hvc1":
        logger.debug("Processing HEVC thumbnail")
        guard let heicData = try await createHEICFromHEVC(info, hevcData: data) else {
            logger.error("Failed to create HEIC from HEVC")
            return nil
        }
        return Thumbnail(
            data: heicData, rotation: rotation, type: "heic", width: width, height: height
        )

    default:
        logger.error("Unsupported thumbnail type: \(info.type)")
        return nil
    }
}

// MARK: - Image Creation

/// Create a platform image from thumbnail data
public func createImageFromThumbnailData(_ thumbnailData: Data) -> PlatformImage? {
    createImageFromThumbnailData(thumbnailData, rotation: 0)
}

/// Create a platform image from thumbnail data with rotation
public func createImageFromThumbnailData(_ thumbnailData: Data, rotation: Int) -> PlatformImage? {
    guard let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else {
        return nil
    }

    let finalImage = (rotation == 0) ? cgImage : rotateCGImage(cgImage, by: rotation)

    #if canImport(UIKit)
        return UIImage(cgImage: finalImage)
    #elseif canImport(AppKit)
        return NSImage(
            cgImage: finalImage, size: NSSize(width: finalImage.width, height: finalImage.height)
        )
    #endif
}

private func rotateCGImage(_ image: CGImage, by degrees: Int) -> CGImage {
    let normalizedDegrees = ((degrees % 360) + 360) % 360
    guard normalizedDegrees != 0 else { return image }

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
    context.rotate(by: CGFloat(normalizedDegrees) * .pi / 180)
    context.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    return context.makeImage() ?? image
}
