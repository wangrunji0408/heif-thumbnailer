import CoreGraphics
import Foundation
import ImageIO
import Logging

private let logger = Logger(label: "com.hdremote.HeifThumbnailer")

// MARK: - HeifReader Implementation

public class HeifReader: ImageReader {
    private let readAt: (UInt64, UInt32) async throws -> Data
    private var thumbnailInfos: [HeifThumbnailEntry]?
    private var metadata: Metadata?

    public required init(readAt: @escaping (UInt64, UInt32) async throws -> Data) {
        self.readAt = readAt
    }

    public func getThumbnailList() async throws -> [ThumbnailInfo] {
        if thumbnailInfos == nil {
            try await loadMetadata()
        }

        return thumbnailInfos?.map { info in
            ThumbnailInfo(
                size: info.size,
                format: info.type == "hvc1" ? "heic" : "jpeg",
                width: info.width,
                height: info.height,
                rotation: info.rotation
            )
        } ?? []
    }

    public func getThumbnail(at index: Int) async throws -> Data {
        if thumbnailInfos == nil {
            try await loadMetadata()
        }

        guard let infos = thumbnailInfos, index < infos.count else {
            throw ImageReaderError.indexOutOfBounds
        }

        let info = infos[index]
        let data = try await readAt(UInt64(info.offset), info.size)
        return try await createThumbnail(from: info, data: data)
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
        let reader = Reader(readAt: readAt)

        guard let metaData = try await readMetaBox(reader: reader) else {
            throw ImageReaderError.metaBoxNotFound
        }

        // Parse the meta box once to get both thumbnails and primary image metadata
        let (thumbnails, primaryMetadata) = parseMetaBoxForBoth(data: metaData)

        thumbnailInfos = thumbnails
        if let width = primaryMetadata.width, let height = primaryMetadata.height {
            metadata = Metadata(width: width, height: height)
        } else {
            throw ImageReaderError.invalidData
        }
    }

    private func parseMetaBoxForBoth(data: Data) -> ([HeifThumbnailEntry], (width: UInt32?, height: UInt32?)) {
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

        // Build thumbnail infos
        let thumbnails = buildThumbnailInfos(
            items: items,
            locations: locations,
            primaryItemId: primaryItemId,
            thumbnailReferences: thumbnailReferences,
            properties: properties,
            propertyAssociations: propertyAssociations
        )

        // Get primary image metadata
        let (_, width, height, _) = extractItemProperties(
            itemId: primaryItemId,
            properties: properties,
            propertyAssociations: propertyAssociations
        )

        return (thumbnails, (width, height))
    }
}

public enum ImageReaderError: Error {
    case metaBoxNotFound
    case indexOutOfBounds
    case invalidData
    case unsupportedFormat
}

// MARK: - Internal Types

struct HeifThumbnailEntry {
    let itemId: UInt32
    let offset: UInt32
    let size: UInt32
    let rotation: Int?
    let width: UInt32?
    let height: UInt32?
    let type: String
    let properties: [ItemProperty]
}

struct ItemProperty {
    let propertyIndex: UInt32
    let propertyType: String
    let rotation: Int?
    let width: UInt32?
    let height: UInt32?
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

// MARK: - HEIC Format Validation

private func readMetaBox(reader: Reader) async throws -> Data? {
    // Read initial header with prefetch for better performance
    try await reader.prefetch(offset: 0, length: 4096)
    let data = try await reader.readAt(offset: 0, length: 4096)
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

    // Search for meta box with optimized reading
    while offset + 8 < 65536 { // Limit search to reasonable file header size
        // Ensure we have enough data in buffer
        if offset + 8 > data.count {
            try await reader.prefetch(offset: offset, length: 8192)
        }

        let headerData = try await reader.readAt(offset: offset, length: 8)
        guard headerData.count == 8 else { break }

        let boxSize = headerData.subdata(in: 0 ..< 4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let boxType = String(data: headerData.subdata(in: 4 ..< 8), encoding: .ascii) ?? ""

        if boxType == "meta" {
            logger.debug("Found meta box: offset=\(offset), size=\(boxSize)")

            // Prefetch the entire meta box for efficient parsing
            try await reader.prefetch(offset: offset, length: UInt32(boxSize))
            return try await reader.readAt(offset: offset, length: boxSize)
        }

        if boxSize <= 8 {
            offset += 8
        } else {
            offset += UInt64(boxSize)
        }
    }

    return nil
}

// MARK: - Meta Box Parsing

private func parseMetaBox(data: Data) -> [HeifThumbnailEntry] {
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
) -> [HeifThumbnailEntry] {
    var thumbnailCandidates: [HeifThumbnailEntry] = []

    for (thumbnailId, masterIds) in thumbnailReferences {
        guard masterIds.contains(primaryItemId),
              let item = items.first(where: { $0.itemId == thumbnailId }),
              let location = locations.first(where: { $0.itemId == thumbnailId })
        else {
            continue
        }

        let (rotation, width, height, associatedProperties) = extractItemProperties(
            itemId: thumbnailId,
            properties: properties,
            propertyAssociations: propertyAssociations
        )

        let thumbnail = HeifThumbnailEntry(
            itemId: thumbnailId,
            offset: location.offset,
            size: location.length,
            rotation: rotation,
            width: width ?? 0,
            height: height ?? 0,
            type: item.itemType,
            properties: associatedProperties
        )

        thumbnailCandidates.append(thumbnail)
        logger.debug(
            "Found thumbnail: itemId=\(thumbnailId), type=\(item.itemType), size=\(width ?? 0)x\(height ?? 0)"
        )
    }

    return thumbnailCandidates
}

private func extractItemProperties(
    itemId: UInt32,
    properties: [ItemProperty],
    propertyAssociations: [ItemPropertyAssociation]
) -> (rotation: Int?, width: UInt32?, height: UInt32?, properties: [ItemProperty]) {
    guard let association = propertyAssociations.first(where: { $0.itemId == itemId }) else {
        return (nil, nil, nil, [])
    }

    var rotation: Int?
    var width: UInt32?
    var height: UInt32?
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
            width = property.width
            height = property.height
        default:
            break
        }
    }

    return (rotation, width, height, associatedProperties)
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
        let size = (boxType == "ispe") ? parseIspeBox(data: boxData) : nil

        let property = ItemProperty(
            propertyIndex: propertyIndex,
            propertyType: boxType,
            rotation: rotation,
            width: size?.width,
            height: size?.height,
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

private func parseIspeBox(data: Data) -> (width: UInt32, height: UInt32)? {
    guard data.count >= 12 else { return nil }

    let width = data.subdata(in: 4 ..< 8)
        .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    let height = data.subdata(in: 8 ..< 12)
        .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

    return (width: width, height: height)
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

private func createThumbnail(from info: HeifThumbnailEntry, data: Data) async throws -> Data {
    switch info.type {
    case "jpeg":
        logger.debug("Processing JPEG thumbnail")
        return data

    case "hvc1":
        logger.debug("Processing HEVC thumbnail")
        guard let heicData = try await createHEICFromHEVC(info, hevcData: data) else {
            logger.error("Failed to create HEIC from HEVC")
            throw ImageReaderError.invalidData
        }
        return heicData

    default:
        logger.error("Unsupported thumbnail type: \(info.type)")
        throw ImageReaderError.unsupportedFormat
    }
}
