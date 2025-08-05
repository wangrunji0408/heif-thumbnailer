import Foundation
import OSLog

private let logger = Logger(subsystem: "com.wangrunji.ImageThumbnailer", category: "Mp4Reader")

// MARK: - Mp4Reader Implementation

public class Mp4Reader: ImageReader {
    private let reader: Reader
    private var imageInfos: [Mp4ImageInfo]?
    private var metadata: Metadata?

    public required init(readAt: @escaping (UInt64, UInt32) async throws -> Data) {
        reader = Reader(readAt: readAt)
    }

    public func getThumbnailList() async throws -> [ThumbnailInfo] {
        if imageInfos == nil {
            try await loadMetadata()
        }

        return imageInfos?.map { info in
            ThumbnailInfo(
                size: UInt32(info.data.count),
                format: detectImageFormat(data: info.data),
                width: info.width,
                height: info.height,
                rotation: nil
            )
        } ?? []
    }

    public func getThumbnail(at index: Int) async throws -> Data {
        if imageInfos == nil {
            try await loadMetadata()
        }

        guard let infos = imageInfos, index < infos.count else {
            throw ImageReaderError.indexOutOfBounds
        }

        return infos[index].data
    }

    public func getMetadata() async throws -> Metadata {
        if metadata == nil {
            try await loadMetadata()
        }
        guard let metadata = metadata else {
            logger.error("Metadata not found")
            throw ImageReaderError.invalidData
        }
        return metadata
    }

    private func loadMetadata() async throws {
        // Read file header with prefetch for better performance
        try await reader.prefetch(at: 0, length: 2048)

        // Validate MP4 format
        guard try await validateMp4Format(reader: reader) else {
            logger.error("Invalid MP4 format")
            throw ImageReaderError.invalidData
        }

        // Find moov box
        guard let (moovOffset, moovSize) = try await findMoovBox(reader: reader) else {
            logger.error("Moov box not found")
            throw ImageReaderError.invalidData
        }

        // Prefetch moov box data for efficient parsing
        try await reader.prefetch(at: moovOffset + 8, length: moovSize - 8)
        let moovData = try await reader.read(at: moovOffset + 8, length: moovSize - 8)

        // Parse moov box to find thumbnails and track dimensions
        let (thumbnails, trackDimensions) = parseMoovBoxForBoth(data: moovData)

        // Parse additional metadata like duration
        let duration = parseDuration(data: moovData)

        // If no thumbnails found, try to extract first frame for video files
        var finalThumbnails = thumbnails
        if thumbnails.isEmpty {
            logger.info("No embedded thumbnails found, attempting first frame extraction")
            if let firstFrameThumbnail = try await extractFirstFrame(moovData: moovData) {
                finalThumbnails = [firstFrameThumbnail]
                logger.info("Successfully extracted first frame as thumbnail")
            }
        }

        imageInfos = finalThumbnails
        if let dimensions = trackDimensions {
            metadata = Metadata(
                width: dimensions.width,
                height: dimensions.height,
                duration: duration,
            )
        } else {
            throw ImageReaderError.invalidData
        }
    }

    private func parseMoovBoxForBoth(data: Data) -> (
        [Mp4ImageInfo], (width: UInt32, height: UInt32)?
    ) {
        logger.debug("Parsing moov box, size: \(data.count)")
        var imageInfos: [Mp4ImageInfo] = []
        var trackDimensions: (width: UInt32, height: UInt32)?

        // Try to get track dimensions first
        trackDimensions = parseTrackDimensions(data: data)

        // Try: moov/udta/meta/ilst
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
            } else {
                // 直接在udta中查找缩略图数据
                logger.debug("No meta box found in udta, searching for thumbnails directly")
                imageInfos.append(contentsOf: parseUdtaForThumbnails(data: udtaData))
            }
        }

        return (imageInfos, trackDimensions)
    }

    private func parseTrackDimensions(data: Data) -> (width: UInt32, height: UInt32)? {
        // Look for trak box
        guard let trakData = findBoxData(in: data, boxType: "trak") else {
            return nil
        }

        // Look for tkhd (track header) box within trak
        guard let tkhdData = findBoxData(in: trakData, boxType: "tkhd") else {
            return nil
        }

        // Parse tkhd box to get track dimensions
        // tkhd box structure: version(1) + flags(3) + ... + width(4) + height(4)
        guard tkhdData.count >= 84 else { return nil }

        let width = tkhdData.subdata(in: 76..<80).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
        let height = tkhdData.subdata(in: 80..<84).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }

        // Convert from fixed-point format (16.16) to integers
        let widthInt = width >> 16
        let heightInt = height >> 16

        return (widthInt, heightInt)
    }

    /// Parse video duration from mvhd box in moov
    private func parseDuration(data: Data) -> Double? {
        // Look for mvhd box
        guard let mvhdData = findBoxData(in: data, boxType: "mvhd") else {
            return nil
        }

        // mvhd box structure:
        // version(1) + flags(3) + creation_time(4) + modification_time(4) +
        // timescale(4) + duration(4) + ...
        guard mvhdData.count >= 20 else { return nil }

        // Get timescale (sample rate)
        let timescale = mvhdData.subdata(in: 12..<16).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }

        // Get duration in timescale units
        let durationInTimescale = mvhdData.subdata(in: 16..<20).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }

        // Convert to seconds
        return Double(durationInTimescale) / Double(timescale)
    }

    /// Extract first frame from video track as HEIC thumbnail
    private func extractFirstFrame(moovData: Data) async throws -> Mp4ImageInfo? {
        logger.debug("Starting first frame extraction")
        
        // Find video track information
        guard let videoTrackInfo = findVideoTrackInfo(moovData: moovData) else {
            logger.error("No video track found")
            return nil
        }
        
        // Find the media data offset for the first frame
        guard let firstFrameOffset = try await findFirstFrameOffset(trackInfo: videoTrackInfo) else {
            logger.error("Could not locate first frame")
            return nil
        }
        
        // Read the first frame data
        guard let frameData = try await readFirstFrameData(at: firstFrameOffset, trackInfo: videoTrackInfo) else {
            logger.error("Could not read first frame data")
            return nil
        }
        
        // Convert HEVC frame to HEIC format
        guard let heicData = try await convertHevcFrameToHeic(frameData: frameData, trackInfo: videoTrackInfo) else {
            logger.error("Could not convert HEVC frame to HEIC")
            return nil
        }
        
        return Mp4ImageInfo(
            data: heicData,
            width: videoTrackInfo.width,
            height: videoTrackInfo.height
        )
    }
    
    /// Find video track information from moov data
    private func findVideoTrackInfo(moovData: Data) -> VideoTrackInfo? {
        // Look for trak box
        guard let trakData = findBoxData(in: moovData, boxType: "trak") else {
            return nil
        }
        
        // Check if this is a video track by looking at track header and media info
        guard let tkhdData = findBoxData(in: trakData, boxType: "tkhd"),
              let mdiaData = findBoxData(in: trakData, boxType: "mdia"),
              let hdlrData = findBoxData(in: mdiaData, boxType: "hdlr") else {
            return nil
        }
        
        // Check handler type to confirm this is a video track
        guard hdlrData.count >= 16 else { return nil }
        let handlerType = String(data: hdlrData.subdata(in: 8..<12), encoding: .ascii) ?? ""
        guard handlerType == "vide" else { return nil }
        
        // Parse track dimensions from tkhd
        guard tkhdData.count >= 84 else { return nil }
        let width = tkhdData.subdata(in: 76..<80).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        } >> 16  // Convert from fixed-point
        let height = tkhdData.subdata(in: 80..<84).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        } >> 16  // Convert from fixed-point
        
        // Find sample table for chunk and sample information
        guard let minfData = findBoxData(in: mdiaData, boxType: "minf"),
              let stblData = findBoxData(in: minfData, boxType: "stbl") else {
            return nil
        }
        
        // Extract HEVC configuration from sample description
        let hevcConfig = extractHevcConfig(from: stblData)
        
        return VideoTrackInfo(
            width: width,
            height: height,
            stblData: stblData,
            hevcConfig: hevcConfig
        )
    }
    
    /// Find the offset of the first video frame
    private func findFirstFrameOffset(trackInfo: VideoTrackInfo) async throws -> UInt64? {
        // Look for stco (chunk offset) or co64 (64-bit chunk offset)
        var chunkOffset: UInt64?
        
        if let stcoData = findBoxData(in: trackInfo.stblData, boxType: "stco"),
           stcoData.count >= 8 {
            // 32-bit chunk offsets
            let entryCount = stcoData.subdata(in: 4..<8).withUnsafeBytes {
                $0.load(as: UInt32.self).bigEndian
            }
            if entryCount > 0 && stcoData.count >= 12 {
                let firstChunkOffset32 = stcoData.subdata(in: 8..<12).withUnsafeBytes {
                    $0.load(as: UInt32.self).bigEndian
                }
                chunkOffset = UInt64(firstChunkOffset32)
            }
        } else if let co64Data = findBoxData(in: trackInfo.stblData, boxType: "co64"),
                  co64Data.count >= 8 {
            // 64-bit chunk offsets
            let entryCount = co64Data.subdata(in: 4..<8).withUnsafeBytes {
                $0.load(as: UInt32.self).bigEndian
            }
            if entryCount > 0 && co64Data.count >= 16 {
                chunkOffset = co64Data.subdata(in: 8..<16).withUnsafeBytes {
                    $0.load(as: UInt64.self).bigEndian
                }
            }
        }
        
        return chunkOffset
    }
    
    /// Read the first frame data
    private func readFirstFrameData(at offset: UInt64, trackInfo: VideoTrackInfo) async throws -> Data? {
        // Look for sample size information in stsz box
        guard let stszData = findBoxData(in: trackInfo.stblData, boxType: "stsz"),
              stszData.count >= 12 else {
            logger.error("Sample size table not found")
            return nil
        }
        
        let sampleSize = stszData.subdata(in: 4..<8).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
        
        let frameSize: UInt32
        if sampleSize != 0 {
            // Fixed sample size
            frameSize = sampleSize
        } else {
            // Variable sample sizes - read first entry
            let sampleCount = stszData.subdata(in: 8..<12).withUnsafeBytes {
                $0.load(as: UInt32.self).bigEndian
            }
            guard sampleCount > 0 && stszData.count >= 16 else {
                logger.error("No samples found")
                return nil
            }
            frameSize = stszData.subdata(in: 12..<16).withUnsafeBytes {
                $0.load(as: UInt32.self).bigEndian
            }
        }
        
        logger.debug("Reading first frame: offset=\(offset), size=\(frameSize)")
        return try await reader.read(at: offset, length: frameSize)
    }
    
    /// Convert HEVC frame data to HEIC format
    private func convertHevcFrameToHeic(frameData: Data, trackInfo: VideoTrackInfo) async throws -> Data? {
        logger.debug("Converting HEVC frame to HEIC, frame size: \(frameData.count)")
        
        // Convert length-prefixed NAL units to Annex-B format
        guard let annexBData = convertToAnnexB(frameData: frameData, hevcConfig: trackInfo.hevcConfig) else {
            logger.error("Failed to convert HEVC frame to Annex-B format")
            return nil
        }
        
        logger.debug("Converted to Annex-B format, size: \(annexBData.count)")
        
        // Create a basic HEIC container for the HEVC frame
        let thumbnail = HeifThumbnailEntry(
            itemId: 1,
            offset: 0,
            size: UInt32(annexBData.count),
            rotation: nil,
            width: trackInfo.width,
            height: trackInfo.height,
            type: "hvc1",
            properties: createBasicHevcProperties(width: trackInfo.width, height: trackInfo.height, hevcConfig: trackInfo.hevcConfig)
        )
        
        logger.debug("Creating HEIC container for \(trackInfo.width)x\(trackInfo.height) image")
        let heicData = try await createHEICFromHEVC(thumbnail, hevcData: annexBData)
        
        if let heicData = heicData {
            logger.debug("Successfully created HEIC data, size: \(heicData.count)")
        } else {
            logger.error("Failed to create HEIC data")
        }
        
        return heicData
    }
    
    /// Convert length-prefixed NAL units to Annex-B format with parameter sets
    private func convertToAnnexB(frameData: Data, hevcConfig: Data?) -> Data? {
        var annexBData = Data()
        
        // First, add parameter sets from HEVC configuration
        if let hevcConfig = hevcConfig {
            logger.debug("Adding parameter sets from HEVC config, size: \(hevcConfig.count)")
            if let parameterSets = extractParameterSets(from: hevcConfig) {
                logger.debug("Found \(parameterSets.count) parameter sets")
                for (index, paramSet) in parameterSets.enumerated() {
                    logger.debug("Adding parameter set \(index + 1), size: \(paramSet.count)")
                    // Add start code (0x00000001) before each parameter set
                    annexBData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    annexBData.append(paramSet)
                }
            } else {
                logger.warning("No parameter sets found in HEVC config")
            }
        } else {
            logger.warning("No HEVC config available")
        }
        
        // Convert frame data from length-prefixed to Annex-B format
        var offset = 0
        var nalUnitCount = 0
        
        while offset + 4 < frameData.count {
            // Read NAL unit length (4 bytes, big endian)
            let nalLength = frameData.subdata(in: offset..<offset + 4).withUnsafeBytes {
                $0.load(as: UInt32.self).bigEndian
            }
            
            guard nalLength > 0 && offset + 4 + Int(nalLength) <= frameData.count else {
                logger.debug("Invalid NAL unit at offset \(offset): length=\(nalLength)")
                break
            }
            
            nalUnitCount += 1
            if nalUnitCount <= 5 {  // Log first few NAL units
                logger.debug("NAL unit \(nalUnitCount): offset=\(offset), length=\(nalLength)")
            }
            
            // Add start code (0x00000001)
            annexBData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            
            // Add NAL unit data
            let nalData = frameData.subdata(in: offset + 4..<offset + 4 + Int(nalLength))
            annexBData.append(nalData)
            
            offset += 4 + Int(nalLength)
        }
        
        logger.debug("Converted \(nalUnitCount) NAL units, total Annex-B size: \(annexBData.count)")
        return annexBData.isEmpty ? nil : annexBData
    }
    
    /// Extract parameter sets (VPS, SPS, PPS) from HEVC configuration
    private func extractParameterSets(from hevcConfig: Data) -> [Data]? {
        guard hevcConfig.count >= 23 else { return nil }
        
        var parameterSets: [Data] = []
        var offset = 22 // Skip to numOfArrays field
        
        guard offset < hevcConfig.count else { return nil }
        let numArrays = hevcConfig[offset]
        offset += 1
        
        for _ in 0..<numArrays {
            guard offset + 3 <= hevcConfig.count else { break }
            
            // Skip array_completeness and NAL_unit_type (1 byte)
            offset += 1
            
            // Read number of NAL units in this array
            let numNalus = hevcConfig.subdata(in: offset..<offset + 2).withUnsafeBytes {
                $0.load(as: UInt16.self).bigEndian
            }
            offset += 2
            
            // Extract each NAL unit
            for _ in 0..<numNalus {
                guard offset + 2 <= hevcConfig.count else { break }
                
                let naluLength = hevcConfig.subdata(in: offset..<offset + 2).withUnsafeBytes {
                    $0.load(as: UInt16.self).bigEndian
                }
                offset += 2
                
                guard offset + Int(naluLength) <= hevcConfig.count else { break }
                
                let naluData = hevcConfig.subdata(in: offset..<offset + Int(naluLength))
                parameterSets.append(naluData)
                offset += Int(naluLength)
            }
        }
        
        return parameterSets.isEmpty ? nil : parameterSets
    }
    
    /// Extract HEVC configuration from sample description table
    private func extractHevcConfig(from stblData: Data) -> Data? {
        // Look for sample description (stsd) box
        guard let stsdData = findBoxData(in: stblData, boxType: "stsd"),
              stsdData.count >= 16 else {
            logger.error("Could not find stsd box or box too small")
            return nil
        }
        
        logger.debug("stsd box data size: \(stsdData.count)")
        
        // Parse stsd box: version(1) + flags(3) + entry_count(4) + entries...
        guard stsdData.count >= 8 else {
            logger.error("stsd box too small for header")
            return nil
        }
        
        let entryCount = stsdData.subdata(in: 4..<8).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
        logger.debug("Sample description entry count: \(entryCount)")
        
        guard entryCount > 0 else {
            logger.error("No sample entries found")
            return nil
        }
        
        // Start parsing from offset 8 (after stsd header)
        let entryOffset = 8
        guard stsdData.count > entryOffset + 8 else { 
            logger.error("stsd data too small for sample entry")
            return nil 
        }
        
        // Read first sample entry size
        let entrySize = stsdData.subdata(in: entryOffset..<entryOffset + 4).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
        
        // Read codec type (format)
        let codecType = String(data: stsdData.subdata(in: entryOffset + 4..<entryOffset + 8), encoding: .ascii) ?? ""
        logger.debug("Found codec type: '\(codecType)', entry size: \(entrySize)")
        
        // Log some bytes for debugging
        if stsdData.count > entryOffset + 16 {
            let debugBytes = stsdData.subdata(in: entryOffset..<min(entryOffset + 16, stsdData.count))
            let hexString = debugBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            logger.debug("Sample entry header bytes: \(hexString)")
        }
        
        guard codecType == "hvc1" || codecType == "hev1" else {
            logger.error("Not an HEVC codec: '\(codecType)'")
            return nil
        }
        
        // The sample entry data starts from entryOffset and has size entrySize
        let sampleEntryData = stsdData.subdata(in: entryOffset..<min(entryOffset + Int(entrySize), stsdData.count))
        
        // For HEVC sample entry, the structure is:
        // size(4) + type(4) + reserved(6) + data_reference_index(2) + pre_defined(2) + reserved(2) + 
        // pre_defined(12) + width(2) + height(2) + ... + compressorname(32) + depth(2) + pre_defined(2) + 
        // then extension boxes including hvcC
        
        // The hvcC box should be after the standard video sample entry fields
        // Standard video sample entry is 78 bytes, then comes extension boxes
        let videoSampleEntrySize = 78
        guard sampleEntryData.count > videoSampleEntrySize else {
            logger.error("Sample entry too small for video sample entry + extensions")
            return nil
        }
        
        // Look for hvcC in the extension area
        let extensionData = sampleEntryData.subdata(in: videoSampleEntrySize..<sampleEntryData.count)
        logger.debug("Searching for hvcC in extension data, size: \(extensionData.count)")
        
        let hvcCData = findBoxData(in: extensionData, boxType: "hvcC")
        
        if let hvcCData = hvcCData {
            logger.debug("Found hvcC configuration, size: \(hvcCData.count)")
        } else {
            logger.error("hvcC configuration not found in sample entry")
        }
        
        return hvcCData
    }
    
    /// Create HEVC properties for HEIC container
    private func createBasicHevcProperties(width: UInt32, height: UInt32, hevcConfig: Data?) -> [ItemProperty] {
        var properties: [ItemProperty] = []
        
        // Image spatial extents property (ispe)
        var ispeData = Data()
        ispeData.append(contentsOf: withUnsafeBytes(of: width.bigEndian) { Data($0) })
        ispeData.append(contentsOf: withUnsafeBytes(of: height.bigEndian) { Data($0) })
        properties.append(ItemProperty(
            propertyIndex: 1,
            propertyType: "ispe",
            rotation: nil,
            width: width,
            height: height,
            rawData: ispeData
        ))
        
        // HEVC configuration property (hvcC)
        let hvcCData: Data
        if let hevcConfig = hevcConfig {
            // Use extracted HEVC configuration
            hvcCData = hevcConfig
        } else {
            // Fallback to minimal HEVC configuration
            hvcCData = Data([
                0x01,  // configuration version
                0x01,  // general_profile_space, general_tier_flag, general_profile_idc
                0x40, 0x00, 0x00, 0x00,  // general_profile_compatibility_flags
                0x90, 0x00, 0x00, 0x00, 0x00, 0x00,  // general_constraint_indicator_flags
                0x5d,  // general_level_idc
                0xf0, 0x00,  // min_spatial_segmentation_idc
                0xfc,  // parallelismType
                0xfd,  // chromaFormat
                0xf8,  // bitDepthLumaMinus8
                0xf8,  // bitDepthChromaMinus8
                0x00, 0x00,  // avgFrameRate
                0x0f,  // constantFrameRate, numTemporalLayers, temporalIdNested, lengthSizeMinusOne
                0x00   // numOfArrays (no parameter sets)
            ])
        }
        
        properties.append(ItemProperty(
            propertyIndex: 2,
            propertyType: "hvcC",
            rotation: nil,
            width: nil,
            height: nil,
            rawData: hvcCData
        ))
        
        return properties
    }
}

// MARK: - MP4 Data Structures

private struct Mp4ImageInfo {
    let data: Data
    let width: UInt32?
    let height: UInt32?
}

private struct VideoTrackInfo {
    let width: UInt32
    let height: UInt32
    let stblData: Data
    let hevcConfig: Data?
}

// MARK: - Private Implementation

private func validateMp4Format(reader: Reader) async throws -> Bool {
    let size = try await reader.readUInt32(at: 0)
    let type = try await reader.readString(at: 4, length: 4)
    return size >= 8 && type == "ftyp"
}

private func findMoovBox(reader: Reader) async throws -> (UInt64, UInt32)? {
    var offset: UInt64 = 0

    while true {
        try await reader.prefetch(at: offset, length: 16)
        // Ensure we have header data
        let boxSize32 = try await reader.readUInt32(at: offset)
        let boxType = try await reader.readString(at: offset + 4, length: 4)

        let actualBoxSize: UInt64
        if boxSize32 == 1 {
            // 64-bit box size follows
            actualBoxSize = try await reader.readUInt64(at: offset + 8)
        } else {
            actualBoxSize = UInt64(boxSize32)
        }

        if boxType == "moov" {
            return (offset, UInt32(actualBoxSize))
        }

        offset += actualBoxSize
    }
}

private func findBoxData(in data: Data, boxType: String) -> Data? {
    logger.debug(
        "Searching for box type '\(boxType, privacy: .public)' in data of size \(data.count)")
    var offset: UInt64 = 0
    var boxCount = 0

    // 不预先跳过，在找到meta box时再处理version/flags

    while offset + 8 <= data.count {
        let boxSize = data.subdata(in: Int(offset)..<Int(offset + 4)).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
        let foundType =
            String(data: data.subdata(in: Int(offset + 4)..<Int(offset + 8)), encoding: .ascii)
            ?? ""

        boxCount += 1
        if boxCount <= 20 {  // 只显示前20个box
            logger.debug(
                "Box #\(boxCount): type='\(foundType, privacy: .public)', size=\(boxSize), offset=\(offset)"
            )
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

            logger.debug("Found box '\(boxType, privacy: .public)' with data size \(dataSize)")
            return data.subdata(in: Int(actualDataOffset)..<Int(actualDataOffset + dataSize))
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
        let itemSize = data.subdata(in: Int(offset)..<Int(offset + 4)).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }

        guard itemSize > 8, offset + UInt64(itemSize) <= data.count else {
            offset += 8
            continue
        }

        let itemName =
            String(data: data.subdata(in: Int(offset + 4)..<Int(offset + 8)), encoding: .ascii)
            ?? ""
        let itemData = data.subdata(in: Int(offset + 8)..<Int(offset + UInt64(itemSize)))

        itemCount += 1
        if itemCount <= 10 {  // 只显示前10个item
            logger.debug(
                "Item #\(itemCount): name='\(itemName)', size=\(itemSize), offset=\(offset)")
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
                logger.debug(
                    "Added ThumbnailImage: \(imageData.width ?? 0)x\(imageData.height ?? 0)")
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
        let boxSize = data.subdata(in: Int(offset)..<Int(offset + 4)).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
        let boxType =
            String(data: data.subdata(in: Int(offset + 4)..<Int(offset + 8)), encoding: .ascii)
            ?? ""

        if boxType == "data", boxSize > 16 {
            // data box contains the actual image
            let imageData = data.subdata(in: Int(offset + 16)..<Int(offset + UInt64(boxSize)))
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

    var offset = 2  // Skip JPEG SOI marker (FF D8)

    while offset + 4 < data.count {
        guard data[offset] == 0xFF else { break }

        let marker = data[offset + 1]
        offset += 2

        // Skip padding
        while offset < data.count && data[offset] == 0xFF {
            offset += 1
        }

        if marker == 0xC0 || marker == 0xC2 {  // SOF0 or SOF2
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

private func parseUdtaForThumbnails(data: Data) -> [Mp4ImageInfo] {
    logger.debug("Parsing udta box for thumbnails, size: \(data.count)")
    var imageInfos: [Mp4ImageInfo] = []
    var offset: UInt64 = 0
    var boxCount = 0

    while offset + 8 <= data.count {
        let boxSize = data.subdata(in: Int(offset)..<Int(offset + 4)).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
        let boxType =
            String(data: data.subdata(in: Int(offset + 4)..<Int(offset + 8)), encoding: .ascii)
            ?? ""

        boxCount += 1
        logger.debug(
            "Box #\(boxCount): type='\(boxType, privacy: .public)', size=\(boxSize), offset=\(offset)"
        )

        // 检查是否是缩略图相关的box
        if boxType == "thmb" {
            let boxData = data.subdata(in: Int(offset + 8)..<Int(offset + UInt64(boxSize)))
            if let thumbnailData = extractThumbnailFromBox(data: boxData) {
                imageInfos.append(thumbnailData)
                logger.debug(
                    "Added thumbnail from \(boxType): \(thumbnailData.width ?? 0)x\(thumbnailData.height ?? 0)"
                )
            }
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

    return imageInfos
}

private func extractThumbnailFromBox(data: Data) -> Mp4ImageInfo? {
    logger.debug("Extracting thumbnail from box, size: \(data.count)")

    // 查找JPEG开始标记
    for i in 0..<data.count - 1 {
        if data[i] == 0xFF && data[i + 1] == 0xD8 {
            logger.debug("Found JPEG start marker at offset \(i)")
            let jpegData = data.subdata(in: i..<data.count)

            // 查找JPEG结束标记
            for j in stride(from: jpegData.count - 1, to: 0, by: -1) {
                if jpegData[j - 1] == 0xFF && jpegData[j] == 0xD9 {
                    let finalJpegData = jpegData.subdata(in: 0..<j + 1)
                    logger.debug("Found complete JPEG data, size: \(finalJpegData.count)")
                    let (width, height) = extractJpegDimensions(data: finalJpegData)
                    return Mp4ImageInfo(data: finalJpegData, width: width, height: height)
                }
            }

            // 如果没有找到结束标记，使用剩余数据
            logger.debug("No JPEG end marker found, using remaining data")
            let (width, height) = extractJpegDimensions(data: jpegData)
            return Mp4ImageInfo(data: jpegData, width: width, height: height)
        }
    }

    return nil
}

/// Detect image format based on data header
private func detectImageFormat(data: Data) -> String {
    guard data.count >= 8 else { return "unknown" }
    
    // Check for JPEG
    if data[0] == 0xFF && data[1] == 0xD8 {
        return "jpeg"
    }
    
    // Check for HEIC/HEIF
    if data.count >= 12 {
        let ftyp = String(data: data.subdata(in: 4..<8), encoding: .ascii) ?? ""
        if ftyp == "ftyp" {
            let brand = String(data: data.subdata(in: 8..<12), encoding: .ascii) ?? ""
            if brand == "heic" || brand == "heix" || brand == "heif" {
                return "heic"
            }
        }
    }
    
    return "unknown"
}
