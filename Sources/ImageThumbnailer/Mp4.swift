import Foundation
import Logging

private let logger = Logger(label: "com.hdremote.Mp4Thumbnailer")

// MARK: - Mp4Reader Implementation

public class Mp4Reader: ImageReader {
    private let readAt: (UInt64, UInt32) async throws -> Data
    private var imageInfos: [Mp4ImageInfo]?
    private var metadata: Metadata?

    public required init(readAt: @escaping (UInt64, UInt32) async throws -> Data) {
        self.readAt = readAt
    }

    public func getThumbnailList() async throws -> [ThumbnailInfo] {
        if imageInfos == nil {
            try await loadImageInfos()
        }

        return imageInfos?.map { info in
            ThumbnailInfo(
                size: UInt32(info.data.count),
                format: "jpeg",
                width: info.width,
                height: info.height,
                rotation: nil
            )
        } ?? []
    }

    public func getThumbnail(at index: Int) async throws -> Data {
        if imageInfos == nil {
            try await loadImageInfos()
        }

        guard let infos = imageInfos, index < infos.count else {
            throw ImageReaderError.indexOutOfBounds
        }

        return infos[index].data
    }

    public func getMetadata() async throws -> Metadata? {
        if metadata == nil {
            try await loadMetadata()
        }
        return metadata
    }

    private func loadImageInfos() async throws {
        // Read file header
        let headerData = try await readAt(0, 1024)

        // Validate MP4 format
        guard validateMp4Format(data: headerData) else {
            throw ImageReaderError.invalidData
        }

        // Find moov box
        guard let (moovOffset, moovSize) = try await findMoovBoxInHeader(headerData: headerData, readAt: readAt) else {
            throw ImageReaderError.invalidData
        }

        let moovData = try await readAt(moovOffset + 8, moovSize - 8)

        // Parse moov box to find thumbnails
        imageInfos = parseMoovBox(data: moovData)
    }

    private func loadMetadata() async throws {
        // For MP4 files, we can get metadata from the first thumbnail
        if let infos = imageInfos, let firstInfo = infos.first,
           let width = firstInfo.width, let height = firstInfo.height
        {
            metadata = Metadata(width: width, height: height)
        }
    }
}

// MARK: - MP4 Data Structures

private struct Mp4ImageInfo {
    let data: Data
    let width: UInt32?
    let height: UInt32?
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

// MARK: - Utility Functions

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
