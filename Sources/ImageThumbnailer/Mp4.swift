import Foundation
import Logging

private let logger = Logger(label: "com.hdremote.Mp4Thumbnailer")

// MARK: - MP4 Data Structures

private struct Mp4ImageInfo {
    let data: Data
    let width: UInt32?
    let height: UInt32?
}

// MARK: - Public API

/// 从MP4文件中读取缩略图
/// - Parameters:
///   - readAt: 异步读取数据的函数
///   - minShortSide: 最小短边长度，如果为nil则返回第一个可用的缩略图
/// - Returns: 缩略图数据和元数据，如果提取失败则返回nil
func readMp4Thumbnail(
    readAt: @escaping (UInt64, UInt32) async throws -> Data,
    minShortSide: UInt32? = nil
) async throws -> Thumbnail? {
    // Step 1: 读取文件头部
    let headerData = try await readAt(0, 1024)

    logger.debug("Read header: \(headerData.count) bytes")

    // 验证这是一个有效的MP4文件
    guard validateMp4Format(data: headerData) else {
        logger.debug("Invalid MP4 format")
        return nil
    }

    // 查找moov box
    guard let (moovOffset, moovSize) = try await findMoovBoxInHeader(headerData: headerData, readAt: readAt) else {
        logger.debug("moov box not found in header")
        return nil
    }

    logger.debug("Found moov box at offset: \(moovOffset), size: \(moovSize)")

    let moovData = try await readAt(moovOffset + 8, moovSize - 8)
    logger.debug("Read additional moov data: \(moovData.count) bytes")

    // 解析moov box，查找缩略图
    let imageInfos = parseMoovBox(data: moovData)

    guard !imageInfos.isEmpty else {
        logger.debug("No thumbnail images found in MP4")
        return nil
    }

    logger.debug("Found \(imageInfos.count) image(s)")

    // 选择最佳的缩略图
    guard let selectedImage = selectBestThumbnail(imageInfos, minShortSide: minShortSide) else {
        logger.debug("No suitable thumbnail found")
        return nil
    }

    logger.debug("Selected thumbnail: \(selectedImage.width ?? 0)x\(selectedImage.height ?? 0)")

    return Thumbnail(
        data: selectedImage.data,
        format: .jpeg,
        width: selectedImage.width,
        height: selectedImage.height,
        rotation: 0
    )
}

// MARK: - Private Implementation

private func validateMp4Format(data: Data) -> Bool {
    guard data.count >= 8 else { return false }

    let size = data.subdata(in: 0 ..< 4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    let type = String(data: data.subdata(in: 4 ..< 8), encoding: .ascii) ?? ""

    return size >= 8 && type == "ftyp"
}

private func findMoovBoxInHeader(headerData: Data, readAt: @escaping (UInt64, UInt32) async throws -> Data) async throws -> (UInt64, UInt32)? {
    var offset: UInt64 = 0

    while true {
        let data: Data
        if offset + 8 <= headerData.count {
            data = headerData.subdata(in: Int(offset) ..< Int(offset + 8))
        } else {
            data = try await readAt(offset, 8)
        }

        if data.count < 8 {
            return nil
        }

        let boxSize = data.subdata(in: 0 ..< 4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let boxType = String(data: data.subdata(in: 4 ..< 8), encoding: .ascii) ?? ""

        if boxType == "moov" {
            return (offset, boxSize)
        }

        if boxSize <= 8 {
            offset += 8 // 跳过无效box
        } else {
            offset += UInt64(boxSize)
        }
    }
}

private func parseMoovBox(data: Data) -> [Mp4ImageInfo] {
    logger.debug("Parsing moov box, size: \(data.count)")
    var imageInfos: [Mp4ImageInfo] = []

    // 尝试：moov/udta/meta/ilst
    if let udtaData = findBoxData(in: data, boxType: "udta") {
        logger.debug("Found udta box, size: \(udtaData.count)")
        // 在udta box中查找meta box
        if let metaData = findBoxData(in: udtaData, boxType: "meta") {
            logger.debug("Found meta box in udta, size: \(metaData.count)")
            // 在meta box中查找ilst box
            if let ilstData = findBoxData(in: metaData, boxType: "ilst") {
                logger.debug("Found ilst box in udta/meta, size: \(ilstData.count)")
                imageInfos.append(contentsOf: parseIlstBox(data: ilstData))
            }
        }
    }

    return imageInfos
}

private func findBoxData(in data: Data, boxType: String) -> Data? {
    logger.debug("Searching for box type '\(boxType)' in data of size \(data.count)")
    var offset: UInt64 = 0
    var boxCount = 0

    // 不预先跳过，在找到meta box时再处理version/flags

    while offset + 8 <= data.count {
        let boxSize = data.subdata(in: Int(offset) ..< Int(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let foundType = String(data: data.subdata(in: Int(offset + 4) ..< Int(offset + 8)), encoding: .ascii) ?? ""

        boxCount += 1
        if boxCount <= 20 { // 只显示前20个box
            logger.debug("Box #\(boxCount): type='\(foundType)', size=\(boxSize), offset=\(offset)")
        }

        if foundType == boxType {
            let dataOffset = offset + 8
            var dataSize = UInt64(boxSize) - 8

            guard dataOffset + dataSize <= data.count else {
                logger.debug("Box '\(boxType)' found but data size invalid")
                return nil
            }

            // 对于meta box，需要跳过4字节的version/flags
            var actualDataOffset = dataOffset
            if boxType == "meta", dataSize >= 4 {
                actualDataOffset += 4
                dataSize -= 4
                logger.debug("Skipping 4 bytes version/flags in meta box")
            }

            logger.debug("Found box '\(boxType)' with data size \(dataSize)")
            return data.subdata(in: Int(actualDataOffset) ..< Int(actualDataOffset + dataSize))
        }

        if boxSize <= 8 {
            offset += 8
        } else {
            offset += UInt64(boxSize)
        }

        if offset >= UInt64(data.count) {
            break
        }
    }

    logger.debug("Box '\(boxType)' not found after checking \(boxCount) boxes")
    return nil
}

private func parseIlstBox(data: Data) -> [Mp4ImageInfo] {
    logger.debug("Parsing ilst box, size: \(data.count)")
    var imageInfos: [Mp4ImageInfo] = []
    var offset: UInt64 = 0
    var itemCount = 0

    while offset + 8 <= data.count {
        let itemSize = data.subdata(in: Int(offset) ..< Int(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        guard itemSize > 8, offset + UInt64(itemSize) <= data.count else {
            offset += 8
            continue
        }

        let itemName = String(data: data.subdata(in: Int(offset + 4) ..< Int(offset + 8)), encoding: .ascii) ?? ""
        let itemData = data.subdata(in: Int(offset + 8) ..< Int(offset + UInt64(itemSize)))

        itemCount += 1
        if itemCount <= 10 { // 只显示前10个item
            logger.debug("Item #\(itemCount): name='\(itemName)', size=\(itemSize), offset=\(offset)")
        }

        if itemName == "covr" {
            // Cover Art
            logger.debug("Processing Cover Art item")
            if let imageData = extractImageFromItem(data: itemData) {
                imageInfos.append(imageData)
                logger.debug("Added Cover Art: \(imageData.width ?? 0)x\(imageData.height ?? 0)")
            }
        } else if itemName == "snal" {
            // PreviewImage
            logger.debug("Processing PreviewImage item")
            if let imageData = extractImageFromItem(data: itemData) {
                imageInfos.append(imageData)
                logger.debug("Added PreviewImage: \(imageData.width ?? 0)x\(imageData.height ?? 0)")
            }
        } else if itemName == "tnal" {
            // ThumbnailImage
            logger.debug("Processing ThumbnailImage item")
            if let imageData = extractImageFromItem(data: itemData) {
                imageInfos.append(imageData)
                logger.debug("Added ThumbnailImage: \(imageData.width ?? 0)x\(imageData.height ?? 0)")
            }
        }

        offset += UInt64(itemSize)
    }

    return imageInfos
}

private func extractImageFromItem(data: Data) -> Mp4ImageInfo? {
    logger.debug("extractImageFromItem: size=\(data.count)")
    var offset: UInt64 = 0

    while offset + 8 <= data.count {
        let boxSize = data.subdata(in: Int(offset) ..< Int(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let boxType = String(data: data.subdata(in: Int(offset + 4) ..< Int(offset + 8)), encoding: .ascii) ?? ""

        if boxType == "data", boxSize > 16 {
            // data box contains the actual image
            let imageData = data.subdata(in: Int(offset + 16) ..< Int(offset + UInt64(boxSize)))
            if isJpegData(imageData) {
                let (width, height) = extractJpegDimensions(data: imageData)
                return Mp4ImageInfo(data: imageData, width: width, height: height)
            }
        }

        if boxSize <= 8 {
            offset += 8
        } else {
            offset += UInt64(boxSize)
        }
    }

    return nil
}

private func searchForThumbnailInItem(data: Data) -> Mp4ImageInfo? {
    // 搜索包含JPEG标记的数据
    guard let jpegStart = findJpegMarker(in: data) else { return nil }

    let imageData = data.subdata(in: jpegStart ..< data.count)
    guard isJpegData(imageData) else { return nil }

    let (width, height) = extractJpegDimensions(data: imageData)

    return Mp4ImageInfo(data: imageData, width: width, height: height)
}

// MARK: - Utility Functions

private func findJpegMarker(in data: Data) -> Int? {
    // 查找JPEG文件头 (FF D8)
    for i in 0 ..< (data.count - 1) {
        if data[i] == 0xFF, data[i + 1] == 0xD8 {
            return i
        }
    }
    return nil
}

private func isJpegData(_ data: Data) -> Bool {
    return data.count >= 2 && data[0] == 0xFF && data[1] == 0xD8
}

private func extractJpegDimensions(data: Data) -> (width: UInt32?, height: UInt32?) {
    guard data.count >= 10 else { return (nil, nil) }

    var offset = 2 // Skip JPEG SOI marker (FF D8)

    while offset + 4 < data.count {
        guard data[offset] == 0xFF else { break }

        let marker = data[offset + 1]
        offset += 2

        // Skip padding
        while offset < data.count && data[offset] == 0xFF {
            offset += 1
        }

        if marker == 0xC0 || marker == 0xC2 { // SOF0 or SOF2
            guard offset + 6 < data.count else { break }

            let length = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            guard length >= 8, offset + Int(length) <= data.count else { break }

            let height = UInt32(data[offset + 3]) << 8 | UInt32(data[offset + 4])
            let width = UInt32(data[offset + 5]) << 8 | UInt32(data[offset + 6])

            return (width, height)
        } else {
            // Skip this segment
            guard offset + 2 <= data.count else { break }
            let length = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            offset += Int(length)
        }
    }

    return (nil, nil)
}

private func selectBestThumbnail(_ imageInfos: [Mp4ImageInfo], minShortSide: UInt32?) -> Mp4ImageInfo? {
    guard !imageInfos.isEmpty else { return nil }

    let sortedImages = imageInfos.sorted {
        let firstShortSide = min($0.width ?? 0, $0.height ?? 0)
        let secondShortSide = min($1.width ?? 0, $1.height ?? 0)
        return firstShortSide < secondShortSide
    }

    if let minShortSide = minShortSide {
        // 找到满足最小尺寸要求的第一个图像
        if let suitable = sortedImages.first(where: { image in
            let shortSide = min(image.width ?? 0, image.height ?? 0)
            return shortSide >= minShortSide
        }) {
            return suitable
        }
    }

    // 如果没有找到满足要求的，返回最佳的可用图像
    return sortedImages.last
}
