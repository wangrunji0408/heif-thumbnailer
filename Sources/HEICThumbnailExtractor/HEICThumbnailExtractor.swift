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

/// Efficiently read the first thumbnail from a HEIC file with minimal read operations
/// - Parameter readAt: Async function to read data at specific offset and length
/// - Returns: Data of the first thumbnail, or nil if extraction fails
public func readHEICThumbnail(readAt: @escaping (UInt64, UInt32) async throws -> Data) async throws
    -> Data?
{
    if let result = try await readHEICThumbnailWithRotation(readAt: readAt) {
        return result.data
    }
    return nil
}

/// Efficiently read the first thumbnail from a HEIC file with minimal read operations, including rotation info
/// - Parameter readAt: Async function to read data at specific offset and length
/// - Returns: Tuple containing thumbnail data and rotation angle, or nil if extraction fails
public func readHEICThumbnailWithRotation(readAt: @escaping (UInt64, UInt32) async throws -> Data)
    async throws -> (data: Data, rotation: Int)?
{
    // 第一步：读取文件头，验证HEIC格式并找到meta box
    let headerData = try await readAt(0, 2048)  // 读取前2KB
    guard headerData.count >= 8 else { return nil }

    var offset: UInt64 = 0

    // 解析ftyp box
    guard let (ftypSize, ftypType) = parseBoxHeader(data: headerData, offset: &offset),
        ftypType == "ftyp"
    else {
        logger.error("不是有效的HEIC文件：缺少ftyp box")
        return nil
    }

    // 验证品牌
    if ftypSize >= 12 && offset + 4 <= headerData.count {
        let brandData = headerData.subdata(in: Int(offset)..<Int(offset + 4))
        let brand = String(data: brandData, encoding: .ascii) ?? ""
        guard brand.hasPrefix("hei") else {
            logger.error("不是HEIC文件，品牌: \(brand)")
            return nil
        }
        logger.debug("检测到HEIC文件，品牌: \(brand)")
    }

    // 跳过ftyp box
    offset = UInt64(ftypSize)

    // 在header数据中查找meta box
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
            logger.debug("找到meta box: offset=\(metaOffset), size=\(metaSize)")
            break
        }

        // 移动到下一个box
        if boxSize > 8 && savedOffset + UInt64(boxSize) <= headerData.count {
            offset = savedOffset + UInt64(boxSize)
        } else {
            break
        }
    }

    // 如果在header中没找到meta box，扩大搜索范围
    if metaOffset == 0 {
        let searchData = try await readAt(0, 8192)  // 读取前8KB
        offset = UInt64(ftypSize)

        while offset + 8 < searchData.count {
            let savedOffset = offset
            guard let (boxSize, boxType) = parseBoxHeader(data: searchData, offset: &offset) else {
                break
            }

            if boxType == "meta" {
                metaOffset = savedOffset
                metaSize = boxSize
                logger.debug("在扩展搜索中找到meta box: offset=\(metaOffset), size=\(metaSize)")
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
        logger.error("未找到meta box")
        return nil
    }

    // 第二步：读取meta box内容
    let metaData: Data
    if metaOffset + UInt64(metaSize) <= headerData.count {
        metaData = headerData.subdata(in: Int(metaOffset)..<Int(metaOffset + UInt64(metaSize)))
    } else {
        metaData = try await readAt(metaOffset, metaSize)
        logger.debug("读取meta box数据: \(metaData.count) 字节")
    }

    // 第三步：解析meta box，找到缩略图信息
    let thumbnailInfos = parseMetaBox(data: metaData)
    guard !thumbnailInfos.isEmpty else {
        logger.error("无法解析meta box中的缩略图信息")
        return nil
    }

    // 第四步：读取缩略图数据
    let thumbnailInfo = thumbnailInfos[0]  // 使用第一个缩略图
    let thumbnailData = try await readAt(UInt64(thumbnailInfo.offset), thumbnailInfo.size)

    logger.debug("读取缩略图数据: \(thumbnailData.count) 字节，旋转角度: \(thumbnailInfo.rotation ?? 0)度")

    // 验证数据是否为有效的图像数据
    if thumbnailData.count >= 4 {
        let header = thumbnailData.prefix(4)
        let headerBytes = Array(header)
        logger.debug(
            "缩略图数据头: \(headerBytes.map { String(format: "%02X", $0) }.joined(separator: " "))")

        // 检查是否为JPEG数据 (FF D8 FF)
        if headerBytes[0] == 0xFF && headerBytes[1] == 0xD8 && headerBytes[2] == 0xFF {
            logger.debug("检测到JPEG缩略图")
            return (data: thumbnailData, rotation: thumbnailInfo.rotation ?? 0)
        }

        // 检查是否为HEVC数据 (通常以NAL单元开始)
        if headerBytes[0] == 0x00 && headerBytes[1] == 0x00 && headerBytes[2] == 0x00
            && headerBytes[3] == 0x01
        {
            logger.debug("检测到标准HEVC NAL单元")
            if let heicData = try await createHEICFromHEVC(thumbnailData) {
                return (data: heicData, rotation: thumbnailInfo.rotation ?? 0)
            }
        }

        // 检查HEVC长度前缀格式 (4字节长度 + NAL单元)
        if headerBytes[0] == 0x00 && headerBytes[1] == 0x00 && headerBytes[2] == 0x00 {
            let nalLength = UInt32(headerBytes[3])
            if nalLength > 0 && nalLength < thumbnailData.count {
                logger.debug("检测到HEVC长度前缀格式")
                if let heicData = try await createHEICFromHEVC(thumbnailData) {
                    return (data: heicData, rotation: thumbnailInfo.rotation ?? 0)
                }
            }
        }

        // 检查其他HEVC格式
        if headerBytes[0] == 0x01 {  // 可能是HEVC数据的其他格式
            logger.debug("检测到HEVC数据，尝试包装为HEIC")
            if let heicData = try await createHEICFromHEVC(thumbnailData) {
                return (data: heicData, rotation: thumbnailInfo.rotation ?? 0)
            }
        }

        // 对于其他格式，尝试直接返回原始数据
        logger.debug("未识别的数据格式，返回原始数据")
    }

    return (data: thumbnailData, rotation: thumbnailInfo.rotation ?? 0)
}

// MARK: - HEIC解析结构体和函数

private struct ThumbnailInfo {
    let itemId: UInt32
    let offset: UInt32
    let size: UInt32
    let rotation: Int?  // 添加旋转角度信息
}

private struct MdatInfo {
    let offset: UInt64
    let size: UInt32
    let dataOffset: UInt64  // mdat数据开始的实际偏移
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
    let rotation: Int?  // 旋转角度（度数）
}

private struct ItemPropertyAssociation {
    let itemId: UInt32
    let propertyIndices: [UInt32]
}

/// 解析box头部
private func parseBoxHeader(data: Data, offset: inout UInt64) -> (UInt32, String)? {
    guard offset + 8 <= data.count else { return nil }

    let sizeData = data.subdata(in: Int(offset)..<Int(offset + 4))
    let typeData = data.subdata(in: Int(offset + 4)..<Int(offset + 8))

    let size = sizeData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    let type = String(data: typeData, encoding: .ascii) ?? ""

    offset += 8
    return (size, type)
}

/// 解析meta box
private func parseMetaBox(data: Data) -> [ThumbnailInfo] {
    var offset: UInt64 = 8  // 跳过meta box头部

    // 跳过version和flags
    offset += 4

    var items: [ItemInfo] = []
    var locations: [ItemLocation] = []
    var primaryItemId: UInt32 = 0
    var thumbnailReferences: [(from: UInt32, to: [UInt32])] = []
    var properties: [ItemProperty] = []
    var propertyAssociations: [ItemPropertyAssociation] = []

    logger.debug("开始解析meta box，数据大小: \(data.count) 字节")

    // 解析meta box中的子box
    while offset + 8 < data.count {
        let savedOffset = offset
        guard let (boxSize, boxType) = parseBoxHeader(data: data, offset: &offset) else {
            logger.debug("无法解析box头部，停止解析")
            break
        }

        logger.debug("发现box: 类型=\(boxType), 大小=\(boxSize), 偏移=\(savedOffset)")

        let boxData = data.subdata(
            in: Int(savedOffset + 8)..<min(Int(savedOffset + UInt64(boxSize)), data.count))

        switch boxType {
        case "pitm":  // Primary Item box
            if let itemId = parsePrimaryItem(data: boxData) {
                primaryItemId = itemId
                logger.debug("主要项目ID: \(itemId)")
            } else {
                logger.debug("无法解析主要项目ID")
            }

        case "iinf":  // Item Info box
            items = parseItemInfo(data: boxData)
            logger.debug("找到 \(items.count) 个项目")
            for item in items {
                logger.debug("  项目: ID=\(item.itemId), 类型=\(item.itemType)")
            }

        case "iloc":  // Item Location box
            locations = parseItemLocation(data: boxData)
            logger.debug("找到 \(locations.count) 个位置信息")
            for location in locations {
                logger.debug(
                    "  位置: ID=\(location.itemId), 偏移=\(location.offset), 大小=\(location.length)")
            }

        case "iref":  // Item Reference box - 关键的缩略图引用信息
            thumbnailReferences = parseItemReference(data: boxData)
            logger.debug("找到 \(thumbnailReferences.count) 个引用关系")
            for (from, to) in thumbnailReferences {
                logger.debug("  引用: \(from) -> \(to)")
            }

        case "iprp":  // Item Properties box
            let (props, assocs) = parseItemProperties(data: boxData)
            properties = props
            propertyAssociations = assocs
            logger.debug("找到 \(properties.count) 个属性和 \(propertyAssociations.count) 个关联")

        default:
            logger.debug("跳过未知box类型: \(boxType)")
            break
        }

        // 移动到下一个box
        if boxSize > 8 {
            offset = savedOffset + UInt64(boxSize)
        } else {
            logger.debug("box大小异常: \(boxSize)，停止解析")
            break
        }
    }

    logger.debug(
        "解析完成 - 主要项目ID: \(primaryItemId), 项目数: \(items.count), 位置数: \(locations.count), 引用数: \(thumbnailReferences.count)"
    )

    // 根据 iref 信息查找缩略图
    // 在 iref 中，缩略图的引用类型是 "thmb"，from_item_ID 是缩略图，to_item_ID 是主图像
    var thumbnailCandidates: [ThumbnailInfo] = []

    for (thumbnailId, masterIds) in thumbnailReferences {
        logger.debug("检查引用: 缩略图ID=\(thumbnailId), 主图像IDs=\(masterIds), 主要项目ID=\(primaryItemId)")

        // 检查这个缩略图是否引用了主图像
        if masterIds.contains(primaryItemId) {
            logger.debug("找到匹配的缩略图引用: \(thumbnailId) -> \(masterIds)")

            // 找到对应的项目信息和位置信息
            if let item = items.first(where: { $0.itemId == thumbnailId }),
                let location = locations.first(where: { $0.itemId == thumbnailId })
            {

                // 查找该项目的旋转属性
                var rotation: Int? = nil
                if let association = propertyAssociations.first(where: { $0.itemId == thumbnailId })
                {
                    for propertyIndex in association.propertyIndices {
                        if let property = properties.first(where: {
                            $0.propertyIndex == propertyIndex
                        }),
                            property.propertyType == "irot",
                            let rot = property.rotation
                        {
                            rotation = rot
                            break
                        }
                    }
                }

                let thumbnail = ThumbnailInfo(
                    itemId: thumbnailId, offset: location.offset, size: location.length,
                    rotation: rotation)
                thumbnailCandidates.append(thumbnail)
                logger.debug(
                    "找到缩略图: itemId=\(thumbnailId), 类型=\(item.itemType), offset=\(location.offset), size=\(location.length), 旋转=\(rotation ?? 0)度"
                )
            } else {
                logger.debug("无法找到缩略图ID \(thumbnailId) 对应的项目信息或位置信息")
                logger.debug("  项目信息存在: \(items.first(where: { $0.itemId == thumbnailId }) != nil)")
                logger.debug(
                    "  位置信息存在: \(locations.first(where: { $0.itemId == thumbnailId }) != nil)")
            }
        } else {
            logger.debug("缩略图 \(thumbnailId) 不引用主图像 \(primaryItemId)")
        }
    }

    logger.debug("最终找到 \(thumbnailCandidates.count) 个缩略图候选")

    // 按优先级排序缩略图：JPEG > HEVC
    thumbnailCandidates.sort { thumbnail1, thumbnail2 in
        let item1 = items.first(where: { $0.itemId == thumbnail1.itemId })
        let item2 = items.first(where: { $0.itemId == thumbnail2.itemId })

        let type1 = item1?.itemType ?? ""
        let type2 = item2?.itemType ?? ""

        // JPEG格式优先
        if type1 == "jpeg" && type2 != "jpeg" {
            return true
        } else if type1 != "jpeg" && type2 == "jpeg" {
            return false
        }

        // 其他情况按itemId排序
        return thumbnail1.itemId < thumbnail2.itemId
    }

    return thumbnailCandidates
}

/// 解析Primary Item box
private func parsePrimaryItem(data: Data) -> UInt32? {
    guard data.count >= 6 else { return nil }

    let offset = 4  // 跳过version和flags
    let itemIdData = data.subdata(in: offset..<offset + 2)
    return itemIdData.withUnsafeBytes { UInt32($0.load(as: UInt16.self).bigEndian) }
}

/// 解析Item Info box
private func parseItemInfo(data: Data) -> [ItemInfo] {
    var items: [ItemInfo] = []
    var offset = 4  // 跳过version和flags

    guard offset + 2 < data.count else { return items }

    let entryCountData = data.subdata(in: offset..<offset + 2)
    let entryCount = entryCountData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
    offset += 2

    logger.debug("Item Info条目数: \(entryCount)")

    for i in 0..<entryCount {  // 移除50个项目的限制
        guard offset + 8 < data.count else {
            logger.debug("数据不足，已解析 \(i) 个项目，停止解析")
            break
        }

        // 解析infe box
        let savedOffset = offset
        var localOffset = UInt64(offset)
        guard let (infeSize, infeType) = parseBoxHeader(data: data, offset: &localOffset) else {
            logger.debug("无法解析第 \(i) 个项目的box头部")
            break
        }

        if infeType == "infe" && infeSize > 8 {
            let infeData = data.subdata(
                in: Int(localOffset)..<min(Int(savedOffset + Int(infeSize)), data.count))
            if let item = parseInfeBox(data: infeData) {
                items.append(item)
                logger.debug("项目 \(i): ID=\(item.itemId), 类型=\(item.itemType)")
            } else {
                logger.debug("无法解析第 \(i) 个项目的infe box")
            }
        } else {
            logger.debug("第 \(i) 个项目不是有效的infe box: 类型=\(infeType), 大小=\(infeSize)")
        }

        offset = savedOffset + Int(infeSize)
    }

    return items
}

/// 解析单个infe box
private func parseInfeBox(data: Data) -> ItemInfo? {
    guard data.count >= 8 else { return nil }

    var offset = 4  // 跳过version和flags

    let itemIdData = data.subdata(in: offset..<offset + 2)
    let itemId = itemIdData.withUnsafeBytes { UInt32($0.load(as: UInt16.self).bigEndian) }
    offset += 2

    offset += 2  // 跳过item_protection_index

    // 读取item_type (4字节)
    guard offset + 4 <= data.count else { return nil }
    let itemTypeData = data.subdata(in: offset..<offset + 4)
    let itemType = String(data: itemTypeData, encoding: .ascii) ?? ""

    return ItemInfo(itemId: itemId, itemType: itemType, itemName: nil)
}

/// 解析Item Location box
private func parseItemLocation(data: Data) -> [ItemLocation] {
    var locations: [ItemLocation] = []
    var offset = 4  // 跳过version和flags

    guard offset + 2 < data.count else { return locations }

    // 检查版本
    let version = data.count > 0 ? data[0] : 0

    // 解析offset_size, length_size等 (16位值)
    let values4Data = data.subdata(in: offset..<offset + 2)
    let values4 = values4Data.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }

    let offsetSize = (values4 >> 12) & 0xF
    let lengthSize = (values4 >> 8) & 0xF
    let baseOffsetSize = (values4 >> 4) & 0xF
    let indexSize = (version == 1 || version == 2) ? (values4 & 0xF) : 0

    offset += 2

    // 读取 item count
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
        "Item Location条目数: \(itemCount), offsetSize=\(offsetSize), lengthSize=\(lengthSize), baseOffsetSize=\(baseOffsetSize), indexSize=\(indexSize)"
    )

    for i in 0..<itemCount {  // 移除50个项目的限制
        // 读取 item ID
        var itemId: UInt32 = 0
        if version < 2 {
            guard offset + 2 <= data.count else {
                logger.debug("数据不足，已解析 \(i) 个位置，停止解析")
                break
            }
            let itemIdData = data.subdata(in: offset..<offset + 2)
            itemId = UInt32(itemIdData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
            offset += 2
        } else {
            guard offset + 4 <= data.count else {
                logger.debug("数据不足，已解析 \(i) 个位置，停止解析")
                break
            }
            let itemIdData = data.subdata(in: offset..<offset + 4)
            itemId = itemIdData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            offset += 4
        }

        logger.debug("解析项目 \(i): itemId=\(itemId), 当前offset=\(offset)")

        // 读取 construction_method (version >= 1)
        if version >= 1 {
            guard offset + 2 <= data.count else {
                logger.debug("数据不足，跳过项目 \(itemId)")
                break
            }
            offset += 2  // 跳过 construction_method
        }

        // 跳过data_reference_index
        guard offset + 2 <= data.count else {
            logger.debug("数据不足，跳过项目 \(itemId)")
            break
        }
        offset += 2

        // 跳过base_offset
        guard offset + Int(baseOffsetSize) <= data.count else {
            logger.debug("数据不足，跳过项目 \(itemId)")
            break
        }
        offset += Int(baseOffsetSize)

        // 读取 extent count
        guard offset + 2 <= data.count else {
            logger.debug("数据不足，跳过项目 \(itemId)")
            break
        }

        let extentCountData = data.subdata(in: offset..<offset + 2)
        let extentCount = extentCountData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        offset += 2

        logger.debug("项目 \(itemId) 有 \(extentCount) 个extent")

        // 检查 extent 数量是否合理
        if extentCount > 100 {
            logger.warning("警告: 项目 \(itemId) 的 extent 数量异常 (\(extentCount))，可能是解析错误，跳过")
            break
        }

        // 只读取第一个extent的信息（通常缩略图只有一个extent）
        if extentCount > 0 {
            let extentSize = Int(indexSize) + Int(offsetSize) + Int(lengthSize)
            guard offset + extentSize <= data.count else {
                logger.debug("数据不足，跳过项目 \(itemId)")
                break
            }

            // 跳过extent_index
            offset += Int(indexSize)

            // 读取extent_offset
            var itemOffset: UInt32 = 0
            if offsetSize == 4 {
                guard offset + 4 <= data.count else {
                    logger.debug("数据不足，跳过项目 \(itemId)")
                    break
                }
                let offsetData = data.subdata(in: offset..<offset + 4)
                itemOffset = offsetData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                offset += 4
            } else if offsetSize == 8 {
                guard offset + 8 <= data.count else {
                    logger.debug("数据不足，跳过项目 \(itemId)")
                    break
                }
                let offsetData = data.subdata(in: offset..<offset + 8)
                let offset64 = offsetData.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
                itemOffset = UInt32(offset64 & 0xFFFF_FFFF)
                offset += 8
            }

            // 读取extent_length
            var itemLength: UInt32 = 0
            if lengthSize == 4 {
                guard offset + 4 <= data.count else {
                    logger.debug("数据不足，跳过项目 \(itemId)")
                    break
                }
                let lengthData = data.subdata(in: offset..<offset + 4)
                itemLength = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                offset += 4
            } else if lengthSize == 8 {
                guard offset + 8 <= data.count else {
                    logger.debug("数据不足，跳过项目 \(itemId)")
                    break
                }
                let lengthData = data.subdata(in: offset..<offset + 8)
                let length64 = lengthData.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
                itemLength = UInt32(length64 & 0xFFFF_FFFF)
                offset += 8
            }

            locations.append(ItemLocation(itemId: itemId, offset: itemOffset, length: itemLength))
            logger.debug("位置信息: itemId=\(itemId), offset=\(itemOffset), length=\(itemLength)")

            // 跳过剩余的extents
            let remainingExtents = Int(extentCount) - 1
            let remainingSize = remainingExtents * extentSize

            if remainingSize > 0 {
                guard offset + remainingSize <= data.count else {
                    logger.warning("警告: 剩余 extent 数据超出范围，停止解析")
                    break
                }
                offset += remainingSize
            }
        }
    }

    return locations
}

/// 解析Item Reference box (iref)
private func parseItemReference(data: Data) -> [(from: UInt32, to: [UInt32])] {
    var references: [(from: UInt32, to: [UInt32])] = []
    var offset = 4  // 跳过version和flags

    // 检查版本来确定ID字段大小
    let version = data.count > 0 ? data[0] : 0
    let idSize = (version == 0) ? 2 : 4

    while offset + 8 < data.count {
        // 解析引用box头部
        guard offset + 8 <= data.count else { break }

        let refBoxSizeData = data.subdata(in: offset..<offset + 4)
        let refBoxSize = refBoxSizeData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        let refBoxTypeData = data.subdata(in: offset + 4..<offset + 8)
        let refBoxType = String(data: refBoxTypeData, encoding: .ascii) ?? ""

        offset += 8

        // 只处理缩略图引用 (thmb)
        if refBoxType == "thmb" && offset + idSize + 2 <= data.count {
            // 读取 from_item_ID
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

            // 读取引用数量
            guard offset + 2 <= data.count else { break }
            let refCountData = data.subdata(in: offset..<offset + 2)
            let refCount = refCountData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            offset += 2

            // 读取 to_item_IDs
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
            logger.debug("缩略图引用: \(fromItemId) -> \(toItemIds)")
        } else {
            // 跳过其他类型的引用
            if refBoxSize > 8 {
                offset += Int(refBoxSize) - 8
            } else {
                break
            }
        }
    }

    return references
}

/// 解析Item Properties box (iprp)
private func parseItemProperties(data: Data) -> ([ItemProperty], [ItemPropertyAssociation]) {
    var properties: [ItemProperty] = []
    var associations: [ItemPropertyAssociation] = []
    var offset = 0

    // 解析iprp box中的子box
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

/// 解析Item Property Container box (ipco)
private func parseItemPropertyContainer(data: Data) -> [ItemProperty] {
    var properties: [ItemProperty] = []
    var offset = 0
    var propertyIndex: UInt32 = 1  // 属性索引从1开始

    while offset + 8 < data.count {
        let savedOffset = offset
        var localOffset = UInt64(offset)
        guard let (boxSize, boxType) = parseBoxHeader(data: data, offset: &localOffset) else {
            break
        }

        let boxData = data.subdata(
            in: Int(localOffset)..<min(Int(savedOffset + Int(boxSize)), data.count))

        var rotation: Int? = nil
        if boxType == "irot" {
            rotation = parseIrotBox(data: boxData)
        }

        let property = ItemProperty(
            propertyIndex: propertyIndex, propertyType: boxType, rotation: rotation)
        properties.append(property)

        logger.debug("属性 \(propertyIndex): 类型=\(boxType), 旋转=\(rotation ?? 0)度")

        propertyIndex += 1
        offset = savedOffset + Int(boxSize)
    }

    return properties
}

/// 解析irot box
private func parseIrotBox(data: Data) -> Int? {
    guard data.count >= 1 else { return nil }

    let rotationValue = data[0]
    // irot box中的值表示逆时针旋转的90度倍数
    // 0 = 0度, 1 = 90度, 2 = 180度, 3 = 270度
    let rotation = Int(rotationValue & 0x03) * 90

    logger.debug("解析irot: 原始值=\(rotationValue), 旋转角度=\(rotation)度")
    return rotation
}

/// 解析Item Property Association box (ipma)
private func parseItemPropertyAssociation(data: Data) -> [ItemPropertyAssociation] {
    var associations: [ItemPropertyAssociation] = []
    var offset = 4  // 跳过version和flags

    guard offset + 4 < data.count else { return associations }

    // 读取entry count (4字节)
    let entryCountData = data.subdata(in: offset..<offset + 4)
    let entryCount = entryCountData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    offset += 4

    logger.debug("属性关联条目数: \(entryCount)")

    for i in 0..<entryCount {  // 移除50个项目的限制
        guard offset + 2 < data.count else {
            logger.debug("数据不足，已解析 \(i) 个属性关联，停止解析")
            break
        }

        // 读取item ID (2字节)
        let itemIdData = data.subdata(in: offset..<offset + 2)
        let itemId = itemIdData.withUnsafeBytes { UInt32($0.load(as: UInt16.self).bigEndian) }
        offset += 2

        guard offset + 1 < data.count else { break }

        // 读取关联数量
        let associationCount = data[offset]
        offset += 1

        logger.debug("项目 \(itemId) 有 \(associationCount) 个属性关联")

        var propertyIndices: [UInt32] = []

        for j in 0..<associationCount {
            guard offset + 1 < data.count else { break }

            // 读取属性索引 (1字节，essential标志位在最高位)
            let propertyByte = data[offset]
            let essential = (propertyByte & 0x80) != 0
            let propertyIndex = UInt32(propertyByte & 0x7F)  // 去掉essential标志位
            propertyIndices.append(propertyIndex)
            offset += 1

            logger.debug("  关联 \(j): 属性索引=\(propertyIndex), essential=\(essential)")
        }

        let association = ItemPropertyAssociation(itemId: itemId, propertyIndices: propertyIndices)
        associations.append(association)

        logger.debug("项目 \(itemId) 关联属性: \(propertyIndices)")
    }

    return associations
}

/// 查找mdat box
private func findMdatBox(
    readAt: @escaping (UInt64, UInt32) async throws -> Data, startOffset: UInt64
) async throws -> MdatInfo? {
    var searchOffset = startOffset
    let chunkSize: UInt32 = 4096

    for _ in 0..<20 {  // 最多搜索20个块
        let searchData = try await readAt(searchOffset, chunkSize)
        guard searchData.count >= 8 else { break }

        var localOffset: UInt64 = 0
        while localOffset + 8 < searchData.count {
            let savedOffset = localOffset
            guard let (boxSize, boxType) = parseBoxHeader(data: searchData, offset: &localOffset)
            else {
                break
            }

            if boxType == "mdat" {
                let mdatOffset = searchOffset + savedOffset
                let dataOffset = mdatOffset + 8  // mdat数据从box头后开始
                return MdatInfo(offset: mdatOffset, size: boxSize, dataOffset: dataOffset)
            }

            // 移动到下一个可能的box位置
            if boxSize > 8 && boxSize < chunkSize {
                localOffset = savedOffset + UInt64(boxSize)
            } else {
                localOffset += 4  // 小步前进
            }
        }

        searchOffset += UInt64(chunkSize - 8)  // 重叠搜索
    }

    return nil
}

/// 将HEVC数据包装为完整的HEIC文件
private func createHEICFromHEVC(_ hevcData: Data) async throws -> Data? {
    // 创建一个完整的HEIC容器来包装HEVC数据
    var heicData = Data()

    // 1. 创建ftyp box
    let ftypBox = createFtypBox()
    heicData.append(ftypBox)

    // 2. 创建meta box (包含完整的元数据结构)
    let metaBox = createCompleteMetaBox(hevcDataSize: UInt32(hevcData.count))
    heicData.append(metaBox)

    // 3. 创建mdat box包含HEVC数据
    let mdatBox = createMdatBox(with: hevcData)
    heicData.append(mdatBox)

    logger.debug("创建HEIC文件，总大小: \(heicData.count) 字节")
    return heicData
}

/// 创建ftyp box
private func createFtypBox() -> Data {
    var data = Data()

    // Box size (4 bytes) - 先写0，后面更新
    let sizeOffset = data.count
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // Box type "ftyp" (4 bytes)
    data.append("ftyp".data(using: .ascii)!)

    // Major brand "heic" (4 bytes)
    data.append("heic".data(using: .ascii)!)

    // Minor version (4 bytes)
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // Compatible brands
    data.append("mif1".data(using: .ascii)!)
    data.append("heic".data(using: .ascii)!)

    // 更新box size
    var boxSize = UInt32(data.count).bigEndian
    data.replaceSubrange(sizeOffset..<sizeOffset + 4, with: Data(bytes: &boxSize, count: 4))

    return data
}

/// 创建完整的meta box
private func createCompleteMetaBox(hevcDataSize: UInt32) -> Data {
    var data = Data()

    // Box size (4 bytes) - 先写0，后面更新
    let sizeOffset = data.count
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // Box type "meta" (4 bytes)
    data.append("meta".data(using: .ascii)!)

    // Version and flags (4 bytes)
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // 1. hdlr box - Handler Reference
    let hdlrBox = createHdlrBox()
    data.append(hdlrBox)

    // 2. pitm box - Primary Item
    let pitmBox = createPitmBox()
    data.append(pitmBox)

    // 3. iinf box - Item Information
    let iinfBox = createIinfBox()
    data.append(iinfBox)

    // 4. iloc box - Item Location
    let ilocBox = createIlocBox(hevcDataSize: hevcDataSize)
    data.append(ilocBox)

    // 5. iprp box - Item Properties (包含 ipco 和 ipma)
    let iprpBox = createIprpBox()
    data.append(iprpBox)

    // 更新box size
    var boxSize = UInt32(data.count).bigEndian
    data.replaceSubrange(sizeOffset..<sizeOffset + 4, with: Data(bytes: &boxSize, count: 4))

    return data
}

/// 创建hdlr box
private func createHdlrBox() -> Data {
    var data = Data()

    // Box size
    var boxSize = UInt32(33).bigEndian  // 8 + 4 + 4 + 4 + 4 + 8 + 1
    data.append(Data(bytes: &boxSize, count: 4))

    // Box type "hdlr"
    data.append("hdlr".data(using: .ascii)!)

    // Version and flags
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // Pre-defined
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // Handler type "pict"
    data.append("pict".data(using: .ascii)!)

    // Reserved
    data.append(Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))

    // Name (null-terminated)
    data.append(Data([0x00]))

    return data
}

/// 创建pitm box
private func createPitmBox() -> Data {
    var data = Data()

    // Box size
    var boxSize = UInt32(14).bigEndian  // 8 + 4 + 2
    data.append(Data(bytes: &boxSize, count: 4))

    // Box type "pitm"
    data.append("pitm".data(using: .ascii)!)

    // Version and flags
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // Item ID (2 bytes for version 0)
    var itemId = UInt16(1).bigEndian
    data.append(Data(bytes: &itemId, count: 2))

    return data
}

/// 创建iinf box
private func createIinfBox() -> Data {
    var data = Data()

    // Box size - 先写0，后面更新
    let sizeOffset = data.count
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // Box type "iinf"
    data.append("iinf".data(using: .ascii)!)

    // Version and flags
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // Entry count
    var entryCount = UInt16(1).bigEndian
    data.append(Data(bytes: &entryCount, count: 2))

    // infe box
    let infeBox = createInfeBox()
    data.append(infeBox)

    // 更新box size
    var boxSize = UInt32(data.count).bigEndian
    data.replaceSubrange(sizeOffset..<sizeOffset + 4, with: Data(bytes: &boxSize, count: 4))

    return data
}

/// 创建infe box
private func createInfeBox() -> Data {
    var data = Data()

    // Box size
    var boxSize = UInt32(21).bigEndian  // 8 + 4 + 2 + 2 + 4 + 1
    data.append(Data(bytes: &boxSize, count: 4))

    // Box type "infe"
    data.append("infe".data(using: .ascii)!)

    // Version and flags
    data.append(Data([0x02, 0x00, 0x00, 0x00]))  // version 2

    // Item ID
    var itemId = UInt16(1).bigEndian
    data.append(Data(bytes: &itemId, count: 2))

    // Item protection index
    var protectionIndex = UInt16(0).bigEndian
    data.append(Data(bytes: &protectionIndex, count: 2))

    // Item type "hvc1"
    data.append("hvc1".data(using: .ascii)!)

    // Item name (null-terminated)
    data.append(Data([0x00]))

    return data
}

/// 创建iloc box
private func createIlocBox(hevcDataSize: UInt32) -> Data {
    var data = Data()

    // Box size
    var boxSize = UInt32(44).bigEndian  // 8 + 4 + 4 + 2 + 2 + 2 + 4 + 2 + 4 + 4 + 8
    data.append(Data(bytes: &boxSize, count: 4))

    // Box type "iloc"
    data.append("iloc".data(using: .ascii)!)

    // Version and flags
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // Offset size, length size, base offset size, index size
    data.append(Data([0x44, 0x00, 0x00, 0x00]))  // offset_size=4, length_size=4, base_offset_size=0, index_size=0

    // Item count
    var itemCount = UInt16(1).bigEndian
    data.append(Data(bytes: &itemCount, count: 2))

    // Item 1
    var itemId = UInt16(1).bigEndian
    data.append(Data(bytes: &itemId, count: 2))

    // Construction method and data reference index
    data.append(Data([0x00, 0x00]))

    // Extent count
    var extentCount = UInt16(1).bigEndian
    data.append(Data(bytes: &extentCount, count: 2))

    // Extent offset (指向mdat数据开始位置，需要计算meta box大小)
    // 这里先写一个占位值，实际应用中需要根据前面box的总大小来计算
    var extentOffset = UInt32(8).bigEndian  // mdat box header size
    data.append(Data(bytes: &extentOffset, count: 4))

    // Extent length
    var extentLength = hevcDataSize.bigEndian
    data.append(Data(bytes: &extentLength, count: 4))

    return data
}

/// 创建iprp box (Item Properties)
private func createIprpBox() -> Data {
    var data = Data()

    // Box size - 先写0，后面更新
    let sizeOffset = data.count
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // Box type "iprp"
    data.append("iprp".data(using: .ascii)!)

    // ipco box (Item Property Container)
    let ipcoBox = createIpcoBox()
    data.append(ipcoBox)

    // ipma box (Item Property Association)
    let ipmaBox = createIpmaBox()
    data.append(ipmaBox)

    // 更新box size
    var boxSize = UInt32(data.count).bigEndian
    data.replaceSubrange(sizeOffset..<sizeOffset + 4, with: Data(bytes: &boxSize, count: 4))

    return data
}

/// 创建ipco box
private func createIpcoBox() -> Data {
    var data = Data()

    // Box size - 先写0，后面更新
    let sizeOffset = data.count
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // Box type "ipco"
    data.append("ipco".data(using: .ascii)!)

    // hvcC box (HEVC Configuration)
    let hvcCBox = createHvcCBox()
    data.append(hvcCBox)

    // 更新box size
    var boxSize = UInt32(data.count).bigEndian
    data.replaceSubrange(sizeOffset..<sizeOffset + 4, with: Data(bytes: &boxSize, count: 4))

    return data
}

/// 创建hvcC box (简化版本)
private func createHvcCBox() -> Data {
    var data = Data()

    // Box size
    var boxSize = UInt32(31).bigEndian  // 8 + 23 (minimal hvcC)
    data.append(Data(bytes: &boxSize, count: 4))

    // Box type "hvcC"
    data.append("hvcC".data(using: .ascii)!)

    // HEVC Configuration (简化版本)
    data.append(
        Data([
            0x01,  // configurationVersion
            0x01,  // general_profile_space, general_tier_flag, general_profile_idc
            0x60, 0x00, 0x00, 0x00,  // general_profile_compatibility_flags
            0x90, 0x00, 0x00, 0x00, 0x00, 0x00,  // general_constraint_indicator_flags
            0x5A,  // general_level_idc
            0xF0, 0x00,  // min_spatial_segmentation_idc
            0xFC,  // parallelismType
            0xFD,  // chromaFormat
            0xF8,  // bitDepthLumaMinus8
            0xF8,  // bitDepthChromaMinus8
            0x00, 0x00,  // avgFrameRate
            0x0F,  // constantFrameRate, numTemporalLayers, temporalIdNested, lengthSizeMinusOne
            0x00,  // numOfArrays
        ]))

    return data
}

/// 创建ipma box
private func createIpmaBox() -> Data {
    var data = Data()

    // Box size
    var boxSize = UInt32(16).bigEndian  // 8 + 4 + 1 + 2 + 1
    data.append(Data(bytes: &boxSize, count: 4))

    // Box type "ipma"
    data.append("ipma".data(using: .ascii)!)

    // Version and flags
    data.append(Data([0x00, 0x00, 0x00, 0x00]))

    // Entry count
    data.append(Data([0x01]))

    // Item ID
    var itemId = UInt16(1).bigEndian
    data.append(Data(bytes: &itemId, count: 2))

    // Association count and property index
    data.append(Data([0x01, 0x01]))  // 1 association, property index 1 (hvcC)

    return data
}

/// 创建mdat box包含HEVC数据
private func createMdatBox(with hevcData: Data) -> Data {
    var data = Data()

    // Box size (4 bytes)
    var totalSize = UInt32(8 + hevcData.count).bigEndian
    data.append(Data(bytes: &totalSize, count: 4))

    // Box type "mdat" (4 bytes)
    data.append("mdat".data(using: .ascii)!)

    // HEVC data
    data.append(hevcData)

    return data
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

    // 如果不需要旋转，直接返回原图
    if rotation == 0 {
        #if canImport(UIKit)
            return UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
            return NSImage(
                cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    // 应用旋转
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

    // 如果不需要旋转，直接返回原图
    if normalizedDegrees == 0 {
        return image
    }

    let width = image.width
    let height = image.height

    // 根据旋转角度确定新的尺寸
    let (newWidth, newHeight): (Int, Int)
    switch normalizedDegrees {
    case 90, 270:
        (newWidth, newHeight) = (height, width)
    default:  // 180度或其他
        (newWidth, newHeight) = (width, height)
    }

    // 创建位图上下文
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

    // 设置变换矩阵
    context.translateBy(x: CGFloat(newWidth) / 2, y: CGFloat(newHeight) / 2)
    context.rotate(by: CGFloat(normalizedDegrees) * .pi / 180)
    context.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)

    // 绘制图像
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    // 获取旋转后的图像
    return context.makeImage() ?? image
}

/// Convenience function to extract thumbnail as platform image
/// - Parameter readAt: Async function to read data at specific offset and length
/// - Returns: Platform-specific image of the first thumbnail, or nil if extraction fails
public func readHEICThumbnailAsImage(readAt: @escaping (UInt64, UInt32) async throws -> Data)
    async throws -> PlatformImage?
{
    guard let result = try await readHEICThumbnailWithRotation(readAt: readAt) else {
        return nil
    }
    return createImageFromThumbnailData(result.data, rotation: result.rotation)
}
