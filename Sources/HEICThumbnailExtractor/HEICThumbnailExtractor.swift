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

private let logger = Logger(label: "com.hdremote.HEICThumbnailExtractor")

public struct Thumbnail {
    public let data: Data
    public let rotation: Int
    public let type: String
    public let width: UInt32
    public let height: UInt32
}

/// Efficiently read the first thumbnail from a HEIC file with minimal read operations, including rotation info
/// - Parameters:
///   - readAt: Async function to read data at specific offset and length
///   - minShortSide: Minimum short side length in pixels. Returns the smallest thumbnail that meets this requirement. If nil, returns the first available thumbnail.
/// - Returns: Tuple containing thumbnail data and rotation angle, or nil if extraction fails
public func readHEICThumbnail(
    readAt: @escaping (UInt64, UInt32) async throws -> Data, minShortSide: UInt32? = nil
)
    async throws -> Thumbnail?
{
    // Step 1: Read file header, verify HEIC format and find meta box
    let headerData = try await readAt(0, 2048)  // Read first 2KB
    guard headerData.count >= 8 else { return nil }

    var offset: UInt64 = 0

    // Parse ftyp box
    guard let (ftypSize, ftypType) = parseBoxHeader(data: headerData, offset: &offset),
        ftypType == "ftyp"
    else {
        logger.error("Not a valid HEIC file: missing ftyp box")
        return nil
    }

    // Verify brand
    if ftypSize >= 12 && offset + 4 <= headerData.count {
        let brandData = headerData.subdata(in: Int(offset)..<Int(offset + 4))
        let brand = String(data: brandData, encoding: .ascii) ?? ""
        guard brand.hasPrefix("hei") else {
            logger.error("Not a HEIC file, brand: \(brand)")
            return nil
        }
        logger.debug("Detected HEIC file, brand: \(brand)")
    }

    // Skip ftyp box
    offset = UInt64(ftypSize)

    // Search for meta box in header data
    var metaOffset: UInt64 = 0
    var metaSize: UInt32 = 0

    while offset + 8 < headerData.count {
        let savedOffset = offset
        guard let (boxSize, boxType) = parseBoxHeader(data: headerData, offset: &offset) else {
            break
        }

        if boxType == "meta" {
            metaOffset = savedOffset
            metaSize = boxSize
            logger.debug("Found meta box: offset=\(metaOffset), size=\(metaSize)")
            break
        }

        // Move to next box
        if boxSize > 8 && savedOffset + UInt64(boxSize) <= headerData.count {
            offset = savedOffset + UInt64(boxSize)
        } else {
            break
        }
    }

    // If meta box not found in header, expand search range
    if metaOffset == 0 {
        let searchData = try await readAt(0, 8192)  // Read first 8KB
        offset = UInt64(ftypSize)

        while offset + 8 < searchData.count {
            let savedOffset = offset
            guard let (boxSize, boxType) = parseBoxHeader(data: searchData, offset: &offset) else {
                break
            }

            if boxType == "meta" {
                metaOffset = savedOffset
                metaSize = boxSize
                logger.debug(
                    "Found meta box in extended search: offset=\(metaOffset), size=\(metaSize)")
                break
            }

            if boxSize > 8 && savedOffset + UInt64(boxSize) <= searchData.count {
                offset = savedOffset + UInt64(boxSize)
            } else {
                break
            }
        }
    }

    guard metaOffset > 0 && metaSize > 0 else {
        logger.error("Meta box not found")
        return nil
    }

    // Step 2: Read meta box content
    let metaData: Data
    if metaOffset + UInt64(metaSize) <= headerData.count {
        metaData = headerData.subdata(in: Int(metaOffset)..<Int(metaOffset + UInt64(metaSize)))
    } else {
        metaData = try await readAt(metaOffset, metaSize)
        logger.debug("Read meta box data: \(metaData.count) bytes")
    }

    // Step 3: Parse meta box, find thumbnail info
    let thumbnailInfos = parseMetaBox(data: metaData, metaOffset: metaOffset)
    guard !thumbnailInfos.isEmpty else {
        logger.error("Unable to parse thumbnail info from meta box")
        return nil
    }
    guard
        let thumbnailInfo = thumbnailInfos.first(where: { thumbnail in
            guard let imageSize = thumbnail.imageSize else { return true }
            return imageSize.shortSide >= minShortSide ?? 0
        })
    else {
        logger.error("No thumbnail found that meets the minShortSide requirement")
        return nil
    }

    // Step 4: Read thumbnail data
    let thumbnailData = try await readAt(UInt64(thumbnailInfo.offset), thumbnailInfo.size)

    logger.debug(
        "Read thumbnail data: \(thumbnailData.count) bytes, rotation: \(thumbnailInfo.rotation ?? 0) degrees"
    )

    // Verify if data is valid image data
    if thumbnailData.count >= 4 {
        let header = thumbnailData.prefix(4)
        let headerBytes = Array(header)
        logger.debug(
            "Thumbnail data header: \(headerBytes.map { String(format: "%02X", $0) }.joined(separator: " "))"
        )

        // Check if it's JPEG data (FF D8 FF)
        if headerBytes[0] == 0xFF && headerBytes[1] == 0xD8 && headerBytes[2] == 0xFF {
            logger.debug("Detected JPEG thumbnail")
            return Thumbnail(
                data: thumbnailData, rotation: thumbnailInfo.rotation ?? 0,
                type: thumbnailInfo.type,
                width: thumbnailInfo.imageSize?.width ?? 0,
                height: thumbnailInfo.imageSize?.height ?? 0
            )
        }

        // Check if it's HEVC data (usually starts with NAL unit)
        if headerBytes[0] == 0x00 && headerBytes[1] == 0x00 && headerBytes[2] == 0x00
            && headerBytes[3] == 0x01
        {
            logger.debug("Detected standard HEVC NAL unit")
            if let heicData = try await createHEICFromHEVC(thumbnailInfo, hevcData: thumbnailData) {
                return Thumbnail(
                    data: heicData, rotation: thumbnailInfo.rotation ?? 0, type: "heic",
                    width: thumbnailInfo.imageSize?.width ?? 0,
                    height: thumbnailInfo.imageSize?.height ?? 0
                )
            }
        }

        // Check HEVC length prefix format (4-byte length + NAL unit)
        if headerBytes[0] == 0x00 && headerBytes[1] == 0x00 && headerBytes[2] == 0x00 {
            let nalLength = UInt32(headerBytes[3])
            if nalLength > 0 && nalLength < thumbnailData.count {
                logger.debug("Detected HEVC length prefix format")
                if let heicData = try await createHEICFromHEVC(
                    thumbnailInfo, hevcData: thumbnailData)
                {
                    return Thumbnail(
                        data: heicData, rotation: thumbnailInfo.rotation ?? 0, type: "heic",
                        width: thumbnailInfo.imageSize?.width ?? 0,
                        height: thumbnailInfo.imageSize?.height ?? 0
                    )
                }
            }
        }

        // Check other HEVC formats
        if headerBytes[0] == 0x01 {  // Might be other HEVC format
            logger.debug("Detected HEVC data, attempting to wrap as HEIC")
            if let heicData = try await createHEICFromHEVC(thumbnailInfo, hevcData: thumbnailData) {
                return Thumbnail(
                    data: heicData, rotation: thumbnailInfo.rotation ?? 0, type: "heic",
                    width: thumbnailInfo.imageSize?.width ?? 0,
                    height: thumbnailInfo.imageSize?.height ?? 0
                )
            }
        }

        // For other formats, try to return raw data
        logger.debug("Unrecognized data format, returning raw data")
    }

    return Thumbnail(
        data: thumbnailData, rotation: thumbnailInfo.rotation ?? 0, type: "unknown",
        width: thumbnailInfo.imageSize?.width ?? 0,
        height: thumbnailInfo.imageSize?.height ?? 0
    )
}

// MARK: - HEIC Structure and Functions

private struct ImageSize {
    let width: UInt32
    let height: UInt32

    var shortSide: UInt32 {
        return min(width, height)
    }
}

private struct BoxInfo {
    let type: String
    let data: Data
    let offset: UInt64
    let size: UInt32
}

private struct ThumbnailInfo {
    let itemId: UInt32
    let offset: UInt32
    let size: UInt32
    let rotation: Int?  // rotation angle
    let imageSize: ImageSize?  // image size
    let type: String  // box type
    let propertyIndices: [UInt32]  // Associated property indices
    let properties: [ItemProperty]  // Associated properties
    let hvcCBox: Data?  // HEVC configuration box data
    let colrBox: Data?  // Color information box data
    let pixiBox: Data?  // Pixel information box data
}

private struct MdatInfo {
    let offset: UInt64
    let size: UInt32
    let dataOffset: UInt64  // Actual offset where mdat data starts
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

private struct ItemProperty {
    let propertyIndex: UInt32
    let propertyType: String
    let rotation: Int?  // Rotation angle (in degrees)
    let imageSize: ImageSize?  // Image size for ispe properties
    let rawData: Data  // Raw box data for reconstruction
}

private struct ItemPropertyAssociation {
    let itemId: UInt32
    let propertyIndices: [UInt32]
}

/// Parse box header
private func parseBoxHeader(data: Data, offset: inout UInt64) -> (UInt32, String)? {
    guard offset + 8 <= data.count else { return nil }

    let sizeData = data.subdata(in: Int(offset)..<Int(offset + 4))
    let typeData = data.subdata(in: Int(offset + 4)..<Int(offset + 8))

    let size = sizeData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    let type = String(data: typeData, encoding: .ascii) ?? ""

    offset += 8
    return (size, type)
}

/// Parse meta box
private func parseMetaBox(data: Data, metaOffset: UInt64 = 0) -> [ThumbnailInfo] {
    var offset: UInt64 = 8  // Skip meta box header

    // Skip version and flags
    offset += 4

    var items: [ItemInfo] = []
    var locations: [ItemLocation] = []
    var primaryItemId: UInt32 = 0
    var thumbnailReferences: [(from: UInt32, to: [UInt32])] = []
    var properties: [ItemProperty] = []
    var propertyAssociations: [ItemPropertyAssociation] = []

    logger.debug("Starting meta box parsing, data size: \(data.count) bytes")

    // Parse sub-boxes in meta box
    while offset + 8 < data.count {
        let savedOffset = offset
        guard let (boxSize, boxType) = parseBoxHeader(data: data, offset: &offset) else {
            logger.debug("Unable to parse box header, stopping parsing")
            break
        }

        logger.debug("Found box: type=\(boxType), size=\(boxSize), offset=\(savedOffset)")

        let boxData = data.subdata(
            in: Int(savedOffset + 8)..<min(Int(savedOffset + UInt64(boxSize)), data.count))

        switch boxType {
        case "pitm":  // Primary Item box
            if let itemId = parsePrimaryItem(data: boxData) {
                primaryItemId = itemId
                logger.debug("Primary item ID: \(itemId)")
            } else {
                logger.debug("Unable to parse primary item ID")
            }

        case "iinf":  // Item Info box
            items = parseItemInfo(data: boxData)
            logger.debug("Found \(items.count) items")
            for item in items {
                logger.debug("  Item: ID=\(item.itemId), type=\(item.itemType)")
            }

        case "iloc":  // Item Location box
            locations = parseItemLocation(data: boxData)
            logger.debug("Found \(locations.count) location entries")
            for location in locations {
                logger.debug(
                    "  Location: ID=\(location.itemId), offset=\(location.offset), size=\(location.length)"
                )
            }

        case "iref":  // Item Reference box - key thumbnail reference info
            thumbnailReferences = parseItemReference(data: boxData)
            logger.debug("Found \(thumbnailReferences.count) references")
            for (from, to) in thumbnailReferences {
                logger.debug("  Reference: \(from) -> \(to)")
            }

        case "iprp":  // Item Properties box
            let (props, assocs) = parseItemProperties(data: boxData)
            properties = props
            propertyAssociations = assocs
            logger.debug(
                "Found \(properties.count) properties and \(propertyAssociations.count) associations"
            )

        default:
            logger.debug("Skipping unknown box type: \(boxType)")
            break
        }

        // Move to next box
        if boxSize > 8 {
            offset = savedOffset + UInt64(boxSize)
        } else {
            logger.debug("Abnormal box size: \(boxSize), stopping parsing")
            break
        }
    }

    logger.debug(
        "Parsing complete - Primary item ID: \(primaryItemId), Items: \(items.count), Locations: \(locations.count), References: \(thumbnailReferences.count)"
    )

    // Find thumbnails based on iref info
    // In iref, thumbnail reference type is "thmb", from_item_ID is thumbnail, to_item_ID is main image
    var thumbnailCandidates: [ThumbnailInfo] = []

    for (thumbnailId, masterIds) in thumbnailReferences {
        logger.debug(
            "Checking reference: Thumbnail ID=\(thumbnailId), Master IDs=\(masterIds), Primary item ID=\(primaryItemId)"
        )

        // Check if this thumbnail references the main image
        if masterIds.contains(primaryItemId) {
            logger.debug("Found matching thumbnail reference: \(thumbnailId) -> \(masterIds)")

            // Find corresponding item info and location info
            if let item = items.first(where: { $0.itemId == thumbnailId }),
                let location = locations.first(where: { $0.itemId == thumbnailId })
            {

                // Find properties for this item
                var rotation: Int? = nil
                var imageSize: ImageSize? = nil
                var associatedProperties: [ItemProperty] = []
                var associatedIndices: [UInt32] = []
                var hvcCData: Data? = nil
                var colrData: Data? = nil
                var pixiData: Data? = nil

                if let association = propertyAssociations.first(where: { $0.itemId == thumbnailId })
                {
                    associatedIndices = association.propertyIndices
                    for propertyIndex in association.propertyIndices {
                        if let property = properties.first(where: {
                            $0.propertyIndex == propertyIndex
                        }) {
                            associatedProperties.append(property)
                            if property.propertyType == "irot", let rot = property.rotation {
                                rotation = rot
                            } else if property.propertyType == "ispe", let size = property.imageSize
                            {
                                imageSize = size
                            }
                        }
                    }
                }

                let thumbnail = ThumbnailInfo(
                    itemId: thumbnailId, offset: location.offset, size: location.length,
                    rotation: rotation, imageSize: imageSize, type: item.itemType,
                    propertyIndices: associatedIndices, properties: associatedProperties,
                    hvcCBox: hvcCData, colrBox: colrData, pixiBox: pixiData)
                thumbnailCandidates.append(thumbnail)
                logger.debug(
                    "Found thumbnail: itemId=\(thumbnailId), type=\(item.itemType), offset=\(location.offset), size=\(location.length), rotation=\(rotation ?? 0) degrees, imageSize=\(imageSize?.width ?? 0)x\(imageSize?.height ?? 0)"
                )
            } else {
                logger.debug(
                    "Unable to find item info or location info for thumbnail ID \(thumbnailId)")
                logger.debug(
                    "  Item info exists: \(items.first(where: { $0.itemId == thumbnailId }) != nil)"
                )
                logger.debug(
                    "  Location info exists: \(locations.first(where: { $0.itemId == thumbnailId }) != nil)"
                )
            }
        } else {
            logger.debug("Thumbnail \(thumbnailId) does not reference main image \(primaryItemId)")
        }
    }

    logger.debug("Found \(thumbnailCandidates.count) thumbnail candidates")

    // Sort thumbnails by size
    thumbnailCandidates.sort { thumbnail1, thumbnail2 in
        let size1 = thumbnail1.imageSize?.shortSide ?? UInt32.max
        let size2 = thumbnail2.imageSize?.shortSide ?? UInt32.max
        return size1 < size2
    }

    return thumbnailCandidates
}

/// Parse Primary Item box
private func parsePrimaryItem(data: Data) -> UInt32? {
    guard data.count >= 6 else { return nil }

    let offset = 4  // Skip version and flags
    let itemIdData = data.subdata(in: offset..<offset + 2)
    return itemIdData.withUnsafeBytes { UInt32($0.load(as: UInt16.self).bigEndian) }
}

/// Parse Item Info box
private func parseItemInfo(data: Data) -> [ItemInfo] {
    var items: [ItemInfo] = []
    var offset = 4  // Skip version and flags

    guard offset + 2 < data.count else { return items }

    let entryCountData = data.subdata(in: offset..<offset + 2)
    let entryCount = entryCountData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
    offset += 2

    logger.debug("Item Info entry count: \(entryCount)")

    for i in 0..<entryCount {  // Remove 50 item limit
        guard offset + 8 < data.count else {
            logger.debug("Insufficient data, parsed \(i) items, stopping")
            break
        }

        // Parse infe box
        let savedOffset = offset
        var localOffset = UInt64(offset)
        guard let (infeSize, infeType) = parseBoxHeader(data: data, offset: &localOffset) else {
            logger.debug("Unable to parse box header for item \(i)")
            break
        }

        if infeType == "infe" && infeSize > 8 {
            let infeData = data.subdata(
                in: Int(localOffset)..<min(Int(savedOffset + Int(infeSize)), data.count))
            if let item = parseInfeBox(data: infeData) {
                items.append(item)
                logger.debug("Item \(i): ID=\(item.itemId), type=\(item.itemType)")
            } else {
                logger.debug("Unable to parse infe box for item \(i)")
            }
        } else {
            logger.debug("Item \(i) is not a valid infe box: type=\(infeType), size=\(infeSize)")
        }

        offset = savedOffset + Int(infeSize)
    }

    return items
}

/// Parse single infe box
private func parseInfeBox(data: Data) -> ItemInfo? {
    guard data.count >= 8 else { return nil }

    var offset = 4  // Skip version and flags

    let itemIdData = data.subdata(in: offset..<offset + 2)
    let itemId = itemIdData.withUnsafeBytes { UInt32($0.load(as: UInt16.self).bigEndian) }
    offset += 2

    offset += 2  // Skip item_protection_index

    // Read item_type (4 bytes)
    guard offset + 4 <= data.count else { return nil }
    let itemTypeData = data.subdata(in: offset..<offset + 4)
    let itemType = String(data: itemTypeData, encoding: .ascii) ?? ""

    return ItemInfo(itemId: itemId, itemType: itemType, itemName: nil)
}

/// Parse Item Location box
private func parseItemLocation(data: Data) -> [ItemLocation] {
    var locations: [ItemLocation] = []
    var offset = 4  // Skip version and flags

    guard offset + 2 < data.count else { return locations }

    // Check version
    let version = data.count > 0 ? data[0] : 0

    // Parse offset_size, length_size etc. (16-bit value)
    let values4Data = data.subdata(in: offset..<offset + 2)
    let values4 = values4Data.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }

    let offsetSize = (values4 >> 12) & 0xF
    let lengthSize = (values4 >> 8) & 0xF
    let baseOffsetSize = (values4 >> 4) & 0xF
    let indexSize = (version == 1 || version == 2) ? (values4 & 0xF) : 0

    offset += 2

    // Read item count
    var itemCount: UInt32 = 0
    if version < 2 {
        guard offset + 2 <= data.count else { return locations }
        let itemCountData = data.subdata(in: offset..<offset + 2)
        itemCount = UInt32(itemCountData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
        offset += 2
    } else {
        guard offset + 4 <= data.count else { return locations }
        let itemCountData = data.subdata(in: offset..<offset + 4)
        itemCount = itemCountData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        offset += 4
    }

    logger.debug(
        "Item Location entry count: \(itemCount), offsetSize=\(offsetSize), lengthSize=\(lengthSize), baseOffsetSize=\(baseOffsetSize), indexSize=\(indexSize)"
    )

    for i in 0..<itemCount {  // Remove 50 item limit
        // Read item ID
        var itemId: UInt32 = 0
        if version < 2 {
            guard offset + 2 <= data.count else {
                logger.debug("Insufficient data, parsed \(i) locations, stopping")
                break
            }
            let itemIdData = data.subdata(in: offset..<offset + 2)
            itemId = UInt32(itemIdData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
            offset += 2
        } else {
            guard offset + 4 <= data.count else {
                logger.debug("Insufficient data, parsed \(i) locations, stopping")
                break
            }
            let itemIdData = data.subdata(in: offset..<offset + 4)
            itemId = itemIdData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            offset += 4
        }

        logger.debug("Parsing item \(i): itemId=\(itemId), current offset=\(offset)")

        // Read construction_method (version >= 1)
        if version >= 1 {
            guard offset + 2 <= data.count else {
                logger.debug("Insufficient data, skipping item \(itemId)")
                break
            }
            offset += 2  // Skip construction_method
        }

        // Skip data_reference_index
        guard offset + 2 <= data.count else {
            logger.debug("Insufficient data, skipping item \(itemId)")
            break
        }
        offset += 2

        // Skip base_offset
        guard offset + Int(baseOffsetSize) <= data.count else {
            logger.debug("Insufficient data, skipping item \(itemId)")
            break
        }
        offset += Int(baseOffsetSize)

        // Read extent count
        guard offset + 2 <= data.count else {
            logger.debug("Insufficient data, skipping item \(itemId)")
            break
        }

        let extentCountData = data.subdata(in: offset..<offset + 2)
        let extentCount = extentCountData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        offset += 2

        logger.debug("Item \(itemId) has \(extentCount) extents")

        // Check if extent count is reasonable
        if extentCount > 100 {
            logger.warning(
                "Warning: Item \(itemId) has abnormal extent count (\(extentCount)), might be parsing error, skipping"
            )
            break
        }

        // Only read first extent info (usually thumbnail has only one extent)
        if extentCount > 0 {
            let extentSize = Int(indexSize) + Int(offsetSize) + Int(lengthSize)
            guard offset + extentSize <= data.count else {
                logger.debug("Insufficient data, skipping item \(itemId)")
                break
            }

            // Skip extent_index
            offset += Int(indexSize)

            // Read extent_offset
            var itemOffset: UInt32 = 0
            if offsetSize == 4 {
                guard offset + 4 <= data.count else {
                    logger.debug("Insufficient data, skipping item \(itemId)")
                    break
                }
                let offsetData = data.subdata(in: offset..<offset + 4)
                itemOffset = offsetData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                offset += 4
            } else if offsetSize == 8 {
                guard offset + 8 <= data.count else {
                    logger.debug("Insufficient data, skipping item \(itemId)")
                    break
                }
                let offsetData = data.subdata(in: offset..<offset + 8)
                let offset64 = offsetData.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
                itemOffset = UInt32(offset64 & 0xFFFF_FFFF)
                offset += 8
            }

            // Read extent_length
            var itemLength: UInt32 = 0
            if lengthSize == 4 {
                guard offset + 4 <= data.count else {
                    logger.debug("Insufficient data, skipping item \(itemId)")
                    break
                }
                let lengthData = data.subdata(in: offset..<offset + 4)
                itemLength = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                offset += 4
            } else if lengthSize == 8 {
                guard offset + 8 <= data.count else {
                    logger.debug("Insufficient data, skipping item \(itemId)")
                    break
                }
                let lengthData = data.subdata(in: offset..<offset + 8)
                let length64 = lengthData.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
                itemLength = UInt32(length64 & 0xFFFF_FFFF)
                offset += 8
            }

            locations.append(ItemLocation(itemId: itemId, offset: itemOffset, length: itemLength))
            logger.debug(
                "Location info: itemId=\(itemId), offset=\(itemOffset), length=\(itemLength)")

            // Skip remaining extents
            let remainingExtents = Int(extentCount) - 1
            let remainingSize = remainingExtents * extentSize

            if remainingSize > 0 {
                guard offset + remainingSize <= data.count else {
                    logger.warning("Warning: Remaining extent data out of range, stopping")
                    break
                }
                offset += remainingSize
            }
        }
    }

    return locations
}

/// Parse Item Reference box (iref)
private func parseItemReference(data: Data) -> [(from: UInt32, to: [UInt32])] {
    var references: [(from: UInt32, to: [UInt32])] = []
    var offset = 4  // Skip version and flags

    // Check version to determine ID field size
    let version = data.count > 0 ? data[0] : 0
    let idSize = (version == 0) ? 2 : 4

    while offset + 8 < data.count {
        // Parse reference box header
        guard offset + 8 <= data.count else { break }

        let refBoxSizeData = data.subdata(in: offset..<offset + 4)
        let refBoxSize = refBoxSizeData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        let refBoxTypeData = data.subdata(in: offset + 4..<offset + 8)
        let refBoxType = String(data: refBoxTypeData, encoding: .ascii) ?? ""

        offset += 8

        // Only process thumbnail references (thmb)
        if refBoxType == "thmb" && offset + idSize + 2 <= data.count {
            // Read from_item_ID
            var fromItemId: UInt32 = 0
            if idSize == 2 {
                let fromIdData = data.subdata(in: offset..<offset + 2)
                fromItemId = UInt32(
                    fromIdData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
            } else {
                let fromIdData = data.subdata(in: offset..<offset + 4)
                fromItemId = fromIdData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            }
            offset += idSize

            // Read reference count
            guard offset + 2 <= data.count else { break }
            let refCountData = data.subdata(in: offset..<offset + 2)
            let refCount = refCountData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            offset += 2

            // Read to_item_IDs
            var toItemIds: [UInt32] = []
            for _ in 0..<refCount {
                guard offset + idSize <= data.count else { break }

                var toItemId: UInt32 = 0
                if idSize == 2 {
                    let toIdData = data.subdata(in: offset..<offset + 2)
                    toItemId = UInt32(
                        toIdData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
                } else {
                    let toIdData = data.subdata(in: offset..<offset + 4)
                    toItemId = toIdData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                }
                toItemIds.append(toItemId)
                offset += idSize
            }

            references.append((from: fromItemId, to: toItemIds))
            logger.debug("Thumbnail reference: \(fromItemId) -> \(toItemIds)")
        } else {
            // Skip other reference types
            if refBoxSize > 8 {
                offset += Int(refBoxSize) - 8
            } else {
                break
            }
        }
    }

    return references
}

/// Parse Item Properties box (iprp)
private func parseItemProperties(data: Data) -> ([ItemProperty], [ItemPropertyAssociation]) {
    var properties: [ItemProperty] = []
    var associations: [ItemPropertyAssociation] = []
    var offset = 0

    // Parse iprp box's sub-boxes
    while offset + 8 < data.count {
        let savedOffset = offset
        var localOffset = UInt64(offset)
        guard let (boxSize, boxType) = parseBoxHeader(data: data, offset: &localOffset) else {
            break
        }

        let boxData = data.subdata(
            in: Int(localOffset)..<min(Int(savedOffset + Int(boxSize)), data.count))

        switch boxType {
        case "ipco":  // Item Property Container
            properties = parseItemPropertyContainer(data: boxData)

        case "ipma":  // Item Property Association
            associations = parseItemPropertyAssociation(data: boxData)

        default:
            break
        }

        offset = savedOffset + Int(boxSize)
    }

    return (properties, associations)
}

/// Parse Item Property Container box (ipco)
private func parseItemPropertyContainer(data: Data) -> [ItemProperty] {
    var properties: [ItemProperty] = []
    var offset = 0
    var propertyIndex: UInt32 = 1  // Property index starts from 1

    while offset + 8 < data.count {
        let savedOffset = offset
        var localOffset = UInt64(offset)
        guard let (boxSize, boxType) = parseBoxHeader(data: data, offset: &localOffset) else {
            break
        }

        let boxData = data.subdata(
            in: Int(localOffset)..<min(Int(savedOffset + Int(boxSize)), data.count))

        var rotation: Int? = nil
        var imageSize: ImageSize? = nil

        if boxType == "irot" {
            rotation = parseIrotBox(data: boxData)
        } else if boxType == "ispe" {
            imageSize = parseIspeBox(data: boxData)
        }

        let property = ItemProperty(
            propertyIndex: propertyIndex, propertyType: boxType, rotation: rotation,
            imageSize: imageSize, rawData: boxData)
        properties.append(property)

        logger.debug(
            "Property \(propertyIndex): type=\(boxType), rotation=\(rotation ?? 0) degrees, size=\(imageSize?.width ?? 0)x\(imageSize?.height ?? 0)"
        )

        propertyIndex += 1
        offset = savedOffset + Int(boxSize)
    }

    return properties
}

/// Parse irot box
private func parseIrotBox(data: Data) -> Int? {
    guard data.count >= 1 else { return nil }

    let rotationValue = data[0]
    // irot box's value represents the number of 90-degree rotations counterclockwise
    // 0 = 0 degrees, 1 = 90 degrees, 2 = 180 degrees, 3 = 270 degrees
    let rotation = Int(rotationValue & 0x03) * 90

    logger.debug("Parsing irot: raw value=\(rotationValue), rotation angle=\(rotation) degrees")
    return rotation
}

/// Parse ispe box (Image Spatial Extents)
private func parseIspeBox(data: Data) -> ImageSize? {
    guard data.count >= 12 else { return nil }

    var offset = 4  // Skip version and flags

    // Read image width (4 bytes)
    let widthData = data.subdata(in: offset..<offset + 4)
    let width = widthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    offset += 4

    // Read image height (4 bytes)
    let heightData = data.subdata(in: offset..<offset + 4)
    let height = heightData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

    logger.debug("Parsing ispe: width=\(width), height=\(height)")
    return ImageSize(width: width, height: height)
}

/// Parse Item Property Association box (ipma)
private func parseItemPropertyAssociation(data: Data) -> [ItemPropertyAssociation] {
    var associations: [ItemPropertyAssociation] = []
    var offset = 4  // Skip version and flags

    guard offset + 4 < data.count else { return associations }

    // Read entry count (4 bytes)
    let entryCountData = data.subdata(in: offset..<offset + 4)
    let entryCount = entryCountData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    offset += 4

    logger.debug("Property association entry count: \(entryCount)")

    for i in 0..<entryCount {
        guard offset + 2 < data.count else {
            logger.debug("Insufficient data, parsed \(i) property associations, stopping")
            break
        }

        // Read item ID (2 bytes)
        let itemIdData = data.subdata(in: offset..<offset + 2)
        let itemId = itemIdData.withUnsafeBytes { UInt32($0.load(as: UInt16.self).bigEndian) }
        offset += 2

        guard offset + 1 < data.count else {
            logger.debug("Insufficient data for association count, item \(itemId)")
            break
        }

        // Read association count
        let associationCount = data[offset]
        offset += 1

        logger.debug("Item \(itemId) has \(associationCount) property associations")

        var propertyIndices: [UInt32] = []

        for j in 0..<associationCount {
            guard offset < data.count else {
                logger.debug(
                    "Insufficient data for property index \(j), item \(itemId), offset: \(offset), data count: \(data.count)"
                )
                break
            }

            // Read property index (1 byte, essential flag in highest bit)
            let propertyByte = data[offset]
            let essential = (propertyByte & 0x80) != 0
            let propertyIndex = UInt32(propertyByte & 0x7F)  // Remove essential flag
            propertyIndices.append(propertyIndex)
            offset += 1

            logger.debug(
                "  Association \(j): property index=\(propertyIndex), essential=\(essential)")
        }

        let association = ItemPropertyAssociation(itemId: itemId, propertyIndices: propertyIndices)
        associations.append(association)

        logger.debug("Item \(itemId) associated properties: \(propertyIndices)")
    }

    return associations
}

/// Wrap HEVC data as a complete HEIC file
private func createHEICFromHEVC(_ thumbnail: ThumbnailInfo, hevcData: Data) async throws -> Data? {
    var heicData = Data()

    // 1. Create ftyp box
    let ftypBox = createFtypBox()
    heicData.append(ftypBox)

    // 2. Create a meta box to calculate its size
    var (metaBox, mdatOffset) = createMetaBox(
        for: thumbnail, hevcDataSize: UInt32(hevcData.count))
    mdatOffset += UInt32(heicData.count)
    heicData.append(metaBox)

    // 3. Update extent location to point to mdat box start
    var extentOffset = UInt32(heicData.count + 8).bigEndian
    heicData.replaceSubrange(
        Int(mdatOffset)..<Int(mdatOffset + 4), with: Data(bytes: &extentOffset, count: 4))

    // 4. Create mdat box with HEVC data
    var mdatBoxSize = UInt32(hevcData.count + 8).bigEndian
    heicData.append(Data(bytes: &mdatBoxSize, count: 4))
    heicData.append("mdat".data(using: .ascii)!)
    heicData.append(hevcData)

    return heicData
}

/// Create ftyp box for HEIC file
private func createFtypBox() -> Data {
    var data = Data()

    // Box size (will be updated)
    data.append(Data(count: 4))

    // Box type
    data.append("ftyp".data(using: .ascii)!)

    // Major brand
    data.append("heic".data(using: .ascii)!)

    // Minor version
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // Compatible brands
    data.append("mif1".data(using: .ascii)!)
    data.append("heic".data(using: .ascii)!)

    // Update box size
    var boxSize = UInt32(data.count).bigEndian
    data.replaceSubrange(0..<4, with: Data(bytes: &boxSize, count: 4))

    return data
}

/// Create meta box for thumbnail
private func createMetaBox(for thumbnail: ThumbnailInfo, hevcDataSize: UInt32)
    -> (Data, UInt32)  // (box data, offset to mdat offset)
{
    var data = Data()

    // Box size (will be updated)
    data.append(Data(count: 4))

    // Box type
    data.append("meta".data(using: .ascii)!)

    // Version and flags
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // hdlr box
    data.append(createHdlrBox())

    // pitm box
    data.append(createPitmBox(itemId: 1))

    // iinf box
    data.append(createIinfBox(for: thumbnail))

    // iprp box
    data.append(createIprpBox(for: thumbnail))

    // iloc box
    var (ilocBox, mdatOffset) = createIlocBox(itemId: 1, dataSize: hevcDataSize)
    mdatOffset += UInt32(data.count)
    data.append(ilocBox)

    // Update box size
    var boxSize = UInt32(data.count).bigEndian
    data.replaceSubrange(0..<4, with: Data(bytes: &boxSize, count: 4))

    return (data, mdatOffset)
}

/// Create hdlr box
private func createHdlrBox() -> Data {
    var data = Data()

    // Box size
    data.append(Data(count: 4))

    // Box type
    data.append("hdlr".data(using: .ascii)!)

    // Version and flags
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // Pre-defined
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // Handler type
    data.append("pict".data(using: .ascii)!)

    // Reserved
    data.append(Data([0x00, 0x00, 0x00, 0x00]))
    data.append(Data([0x00, 0x00, 0x00, 0x00]))
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // Name (empty)
    data.append(Data([0x00]))

    // Update box size
    var boxSize = UInt32(data.count).bigEndian
    data.replaceSubrange(0..<4, with: Data(bytes: &boxSize, count: 4))

    return data
}

/// Create pitm box
private func createPitmBox(itemId: UInt32) -> Data {
    var data = Data()

    // Box size
    data.append(Data(count: 4))

    // Box type
    data.append("pitm".data(using: .ascii)!)

    // Version and flags
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // Item ID
    var itemIdBE = UInt16(itemId).bigEndian
    data.append(Data(bytes: &itemIdBE, count: 2))

    // Update box size
    var boxSize = UInt32(data.count).bigEndian
    data.replaceSubrange(0..<4, with: Data(bytes: &boxSize, count: 4))

    return data
}

/// Create iinf box
private func createIinfBox(for thumbnail: ThumbnailInfo) -> Data {
    var data = Data()

    // Box size (will be updated)
    data.append(Data(count: 4))

    // Box type
    data.append("iinf".data(using: .ascii)!)

    // Version and flags
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // Entry count
    var entryCount = UInt16(1).bigEndian
    data.append(Data(bytes: &entryCount, count: 2))

    // infe box
    data.append(createInfeBox(itemId: 1, itemType: thumbnail.type))

    // Update box size
    var boxSize = UInt32(data.count).bigEndian
    data.replaceSubrange(0..<4, with: Data(bytes: &boxSize, count: 4))

    return data
}

/// Create infe box
private func createInfeBox(itemId: UInt32, itemType: String) -> Data {
    var data = Data()

    // Box size
    data.append(Data(count: 4))

    // Box type
    data.append("infe".data(using: .ascii)!)

    // Version and flags (version 2, flags 0x000000 for main image)
    data.append(Data([0x02, 0x00, 0x00, 0x00]))

    // Item ID
    var itemIdBE = UInt16(itemId).bigEndian
    data.append(Data(bytes: &itemIdBE, count: 2))

    // Item protection index
    data.append(Data([0x00, 0x00]))

    // Item type
    data.append(itemType.padding(toLength: 4, withPad: "\0", startingAt: 0).data(using: .ascii)!)

    // Item name (empty)
    data.append(Data([0x00]))

    // Update box size
    var boxSize = UInt32(data.count).bigEndian
    data.replaceSubrange(0..<4, with: Data(bytes: &boxSize, count: 4))

    return data
}

/// Create iprp box
private func createIprpBox(for thumbnail: ThumbnailInfo) -> Data {
    var data = Data()

    // Box size (will be updated)
    data.append(Data(count: 4))

    // Box type
    data.append("iprp".data(using: .ascii)!)

    // ipco box
    data.append(createIpcoBox(for: thumbnail))

    // ipma box
    data.append(createIpmaBox(for: thumbnail))

    // Update box size
    var boxSize = UInt32(data.count).bigEndian
    data.replaceSubrange(0..<4, with: Data(bytes: &boxSize, count: 4))

    return data
}

/// Create ipco box
private func createIpcoBox(for thumbnail: ThumbnailInfo) -> Data {
    var data = Data()

    // Box size (will be updated)
    data.append(Data(count: 4))

    // Box type
    data.append("ipco".data(using: .ascii)!)

    // Add properties from thumbnail
    for property in thumbnail.properties {
        data.append(createPropertyBox(property: property))
    }

    // Update box size
    var boxSize = UInt32(data.count).bigEndian
    data.replaceSubrange(0..<4, with: Data(bytes: &boxSize, count: 4))

    return data
}

/// Create property box from ItemProperty
private func createPropertyBox(property: ItemProperty) -> Data {
    var data = Data()

    // Box size
    data.append(Data(count: 4))

    // Box type
    data.append(property.propertyType.data(using: .ascii)!)

    // Property data
    data.append(property.rawData)

    // Update box size
    var boxSize = UInt32(data.count).bigEndian
    data.replaceSubrange(0..<4, with: Data(bytes: &boxSize, count: 4))

    return data
}

/// Create ipma box
private func createIpmaBox(for thumbnail: ThumbnailInfo) -> Data {
    var data = Data()

    // Box size
    data.append(Data(count: 4))

    // Box type
    data.append("ipma".data(using: .ascii)!)

    // Version and flags
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // Entry count
    var entryCount = UInt32(1).bigEndian
    data.append(Data(bytes: &entryCount, count: 4))

    // Item ID
    var itemId = UInt16(1).bigEndian
    data.append(Data(bytes: &itemId, count: 2))

    // Association count
    data.append(Data([UInt8(thumbnail.propertyIndices.count)]))

    // Property associations
    for (index, _) in thumbnail.propertyIndices.enumerated() {
        // Property index (1-based) with essential flag
        data.append(Data([UInt8(index + 1) | 0x80]))
    }

    // Update box size
    var boxSize = UInt32(data.count).bigEndian
    data.replaceSubrange(0..<4, with: Data(bytes: &boxSize, count: 4))

    return data
}

/// Create iloc box
private func createIlocBox(itemId: UInt32, dataSize: UInt32) -> (Data, UInt32) {
    var data = Data()

    // Box size
    data.append(Data(count: 4))

    // Box type
    data.append("iloc".data(using: .ascii)!)

    // Version and flags (version 1 to support construction_method)
    data.append(Data([0x01, 0x00, 0x00, 0x00]))

    // Offset size, length size, base offset size, index size
    data.append(Data([0x44, 0x00]))  // offset_size=4, length_size=4, base_offset_size=0, index_size=0

    // Item count
    var itemCount = UInt16(1).bigEndian
    data.append(Data(bytes: &itemCount, count: 2))

    // Item ID (16-bit for version 1)
    var itemIdBE = UInt16(itemId).bigEndian
    data.append(Data(bytes: &itemIdBE, count: 2))

    // Construction method (version >= 1)
    data.append(Data([0x00, 0x00]))

    // Data reference index
    data.append(Data([0x00, 0x00]))

    // Extent count
    data.append(Data([0x00, 0x01]))

    // Extent offset (placeholder)
    let mdatOffset = UInt32(data.count)
    data.append(Data(count: 4))

    // Extent length
    var extentLength = dataSize.bigEndian
    data.append(Data(bytes: &extentLength, count: 4))

    // Update box size
    var boxSize = UInt32(data.count).bigEndian
    data.replaceSubrange(0..<4, with: Data(bytes: &boxSize, count: 4))

    return (data, mdatOffset)
}

/// Create a platform image from HEIC thumbnail data
/// - Parameter thumbnailData: Raw thumbnail data
/// - Returns: Platform-specific image (UIImage on iOS, NSImage on macOS)
public func createImageFromThumbnailData(_ thumbnailData: Data) -> PlatformImage? {
    return createImageFromThumbnailData(thumbnailData, rotation: 0)
}

/// Create a platform image from HEIC thumbnail data with rotation
/// - Parameters:
///   - thumbnailData: Raw thumbnail data
///   - rotation: Rotation angle in degrees (0, 90, 180, 270)
/// - Returns: Platform-specific image (UIImage on iOS, NSImage on macOS)
public func createImageFromThumbnailData(_ thumbnailData: Data, rotation: Int) -> PlatformImage? {
    guard let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil),
        let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else {
        return nil
    }

    // If no rotation needed, return original image
    if rotation == 0 {
        #if canImport(UIKit)
            return UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
            return NSImage(
                cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    // Apply rotation
    let rotatedCGImage = rotateCGImage(cgImage, by: rotation)

    #if canImport(UIKit)
        return UIImage(cgImage: rotatedCGImage)
    #elseif canImport(AppKit)
        return NSImage(
            cgImage: rotatedCGImage,
            size: NSSize(width: rotatedCGImage.width, height: rotatedCGImage.height))
    #endif
}

/// Rotate a CGImage by the specified angle
/// - Parameters:
///   - image: Source CGImage
///   - degrees: Rotation angle in degrees (0, 90, 180, 270)
/// - Returns: Rotated CGImage
private func rotateCGImage(_ image: CGImage, by degrees: Int) -> CGImage {
    let normalizedDegrees = ((degrees % 360) + 360) % 360

    // If no rotation needed, return original image
    if normalizedDegrees == 0 {
        return image
    }

    let width = image.width
    let height = image.height

    // Determine new dimensions based on rotation angle
    let (newWidth, newHeight): (Int, Int)
    switch normalizedDegrees {
    case 90, 270:
        (newWidth, newHeight) = (height, width)
    default:  // 180 degrees or other
        (newWidth, newHeight) = (width, height)
    }

    // Create bitmap context
    guard let colorSpace = image.colorSpace,
        let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: image.bitmapInfo.rawValue)
    else {
        return image
    }

    // Set transformation matrix
    context.translateBy(x: CGFloat(newWidth) / 2, y: CGFloat(newHeight) / 2)
    context.rotate(by: CGFloat(normalizedDegrees) * .pi / 180)
    context.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)

    // Draw image
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    // Get rotated image
    return context.makeImage() ?? image
}

/// Convenience function to extract thumbnail as platform image
/// - Parameters:
///   - readAt: Async function to read data at specific offset and length
///   - minShortSide: Minimum short side length in pixels. Returns the smallest thumbnail that meets this requirement. If nil, returns the first available thumbnail.
/// - Returns: Platform-specific image of the first thumbnail, or nil if extraction fails
public func readHEICThumbnailAsImage(
    readAt: @escaping (UInt64, UInt32) async throws -> Data, minShortSide: UInt32? = nil
)
    async throws -> PlatformImage?
{
    guard
        let result = try await readHEICThumbnail(
            readAt: readAt, minShortSide: minShortSide)
    else {
        return nil
    }
    return createImageFromThumbnailData(result.data, rotation: result.rotation)
}
