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
            // For thumbnail list, we estimate size based on available information
            let estimatedSize: UInt32
            let format: String

            if let embeddedData = info.embeddedData {
                estimatedSize = UInt32(embeddedData.count)
                format = detectImageFormat(data: embeddedData)
            } else if let frameSize = info.frameSize {
                estimatedSize = frameSize * 2  // Estimate HEIC will be roughly 2x HEVC frame size
                format = "heic"
            } else {
                estimatedSize = 0
                format = "unknown"
            }

            return ThumbnailInfo(
                size: estimatedSize,
                format: format,
                width: info.width,
                height: info.height,
                rotation: info.rotation.map { Int($0) }
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

        let info = infos[index]

        // Return embedded thumbnail data directly
        if let embeddedData = info.embeddedData {
            return embeddedData
        }

        // Extract and convert first frame to HEIC
        guard let frameOffset = info.frameOffset,
            let frameSize = info.frameSize,
            let videoTrackInfo = info.videoTrackInfo
        else {
            throw ImageReaderError.invalidData
        }

        // Read frame data
        let frameData = try await reader.read(at: frameOffset, length: frameSize)

        // Convert to HEIC
        guard
            let heicData = try await convertHevcFrameToHeic(
                frameData: frameData, trackInfo: videoTrackInfo)
        else {
            throw ImageReaderError.invalidData
        }

        return heicData
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

        // Parse everything in one pass to avoid redundant operations
        let parsedInfo = parseAllMoovInfo(data: moovData)

        // If no thumbnails found, create placeholder for first frame extraction
        var finalThumbnails = parsedInfo.thumbnails
        if parsedInfo.thumbnails.isEmpty && parsedInfo.videoTrackInfo != nil {
            logger.info("No embedded thumbnails found, preparing first frame extraction info")
            if let firstFrameInfo = try await prepareFirstFrameInfo(
                videoTrackInfo: parsedInfo.videoTrackInfo!)
            {
                finalThumbnails = [firstFrameInfo]
                logger.info("Successfully prepared first frame extraction info")
            }
        }

        imageInfos = finalThumbnails
        if let trackDimensions = parsedInfo.trackDimensions {
            metadata = Metadata(
                width: trackDimensions.width,
                height: trackDimensions.height,
                duration: parsedInfo.duration
            )
        } else {
            throw ImageReaderError.invalidData
        }
    }

    // Consolidated parsing structure to avoid redundant operations
    private struct ParsedMoovInfo {
        let thumbnails: [Mp4ImageInfo]
        let trackDimensions: (width: UInt32, height: UInt32)?
        let duration: Double?
        let videoTrackInfo: VideoTrackInfo?
    }

    private func parseAllMoovInfo(data: Data) -> ParsedMoovInfo {
        logger.debug("Parsing moov box, size: \(data.count)")
        var imageInfos: [Mp4ImageInfo] = []
        var trackDimensions: (width: UInt32, height: UInt32)?
        var rotation: Double?
        var videoTrackInfo: VideoTrackInfo?

        // Parse duration from mvhd box
        let duration = parseDuration(data: data)

        // Single pass through all tracks to find video track info and dimensions
        var offset: UInt64 = 0
        var trackIndex = 0

        while offset + 8 <= data.count {
            let boxSize = data.subdata(in: Int(offset)..<Int(offset + 4)).withUnsafeBytes {
                $0.load(as: UInt32.self).bigEndian
            }
            let boxType =
                String(data: data.subdata(in: Int(offset + 4)..<Int(offset + 8)), encoding: .ascii)
                ?? ""

            guard boxSize > 8 && offset + UInt64(boxSize) <= data.count else {
                offset += 8
                continue
            }

            if boxType == "trak" {
                trackIndex += 1
                let trakData = data.subdata(in: Int(offset + 8)..<Int(offset + UInt64(boxSize)))

                // Parse track info in one pass
                if let trackInfo = parseTrackInfoComplete(
                    trakData: trakData, trackIndex: trackIndex)
                {
                    // Use first video track for dimensions and rotation
                    if trackDimensions == nil && trackInfo.isVideo {
                        trackDimensions = (trackInfo.width, trackInfo.height)
                        rotation = trackInfo.rotation

                        // Create video track info for first frame extraction if needed
                        if let stblData = trackInfo.stblData, let hevcConfig = trackInfo.hevcConfig
                        {
                            videoTrackInfo = VideoTrackInfo(
                                width: trackInfo.width,
                                height: trackInfo.height,
                                stblData: stblData,
                                hevcConfig: hevcConfig,
                                rotation: trackInfo.rotation
                            )
                        }
                    }
                }
            }

            offset += UInt64(boxSize)
        }

        // Parse thumbnails from udta box
        if let udtaData = findBoxData(in: data, boxType: "udta") {
            logger.debug("Found udta box, size: \(udtaData.count)")
            if let metaData = findBoxData(in: udtaData, boxType: "meta") {
                logger.debug("Found meta box in udta, size: \(metaData.count)")
                if let ilstData = findBoxData(in: metaData, boxType: "ilst") {
                    logger.debug("Found ilst box in udta/meta, size: \(ilstData.count)")
                    imageInfos.append(contentsOf: parseIlstBox(data: ilstData, rotation: rotation))
                }
            } else {
                logger.debug("No meta box found in udta, searching for thumbnails directly")
                imageInfos.append(
                    contentsOf: parseUdtaForThumbnails(data: udtaData, rotation: rotation))
            }
        }

        return ParsedMoovInfo(
            thumbnails: imageInfos,
            trackDimensions: trackDimensions,
            duration: duration,
            videoTrackInfo: videoTrackInfo
        )
    }

    // Comprehensive track information structure
    private struct TrackInfoComplete {
        let width: UInt32
        let height: UInt32
        let rotation: Double?
        let isVideo: Bool
        let stblData: Data?
        let hevcConfig: Data?
    }

    // Parse all track information in a single pass
    private func parseTrackInfoComplete(trakData: Data, trackIndex: Int) -> TrackInfoComplete? {
        // Get basic boxes we need
        guard let tkhdData = findBoxData(in: trakData, boxType: "tkhd"),
            let mdiaData = findBoxData(in: trakData, boxType: "mdia"),
            let hdlrData = findBoxData(in: mdiaData, boxType: "hdlr"),
            hdlrData.count >= 16
        else {
            return nil
        }

        // Check if this is a video track
        let handlerType = String(data: hdlrData.subdata(in: 8..<12), encoding: .ascii) ?? ""
        let isVideo = handlerType == "vide"

        if isVideo {
            logger.debug("Track \(trackIndex) is a video track, checking for rotation")
        }

        // Parse dimensions from tkhd
        guard tkhdData.count >= 84 else { return nil }
        let width =
            tkhdData.subdata(in: 76..<80).withUnsafeBytes {
                $0.load(as: UInt32.self).bigEndian
            } >> 16
        let height =
            tkhdData.subdata(in: 80..<84).withUnsafeBytes {
                $0.load(as: UInt32.self).bigEndian
            } >> 16

        // Parse rotation if this is a video track
        var rotation: Double?
        if isVideo {
            rotation = parseRotationFromTkhdData(tkhdData: tkhdData, trackIndex: trackIndex)
            if let rotation = rotation {
                logger.debug("Found rotation \(rotation)° in track \(trackIndex)")
            }
        }

        // Get sample table data and HEVC config if this is a video track
        var stblData: Data?
        var hevcConfig: Data?

        if isVideo {
            if let minfData = findBoxData(in: mdiaData, boxType: "minf"),
                let stblBoxData = findBoxData(in: minfData, boxType: "stbl")
            {
                stblData = stblBoxData
                hevcConfig = extractHevcConfig(from: stblBoxData)
                if let config = hevcConfig {
                    logger.debug("Using extracted HEVC config, size: \(config.count)")
                }
            }
        }

        return TrackInfoComplete(
            width: width,
            height: height,
            rotation: rotation,
            isVideo: isVideo,
            stblData: stblData,
            hevcConfig: hevcConfig
        )
    }

    // Simplified rotation parsing from tkhd data
    private func parseRotationFromTkhdData(tkhdData: Data, trackIndex: Int) -> Double? {
        guard tkhdData.count >= 76 else {
            logger.debug("Track \(trackIndex) tkhd box too small for matrix: \(tkhdData.count)")
            return nil
        }

        // Check version to determine matrix offset
        let version = tkhdData[0]
        let matrixOffset: Int = version == 0 ? 40 : 52

        guard tkhdData.count >= matrixOffset + 36 else {
            logger.debug(
                "Track \(trackIndex) tkhd box too small for matrix at offset \(matrixOffset): \(tkhdData.count)"
            )
            return nil
        }

        // Extract matrix elements a and b for rotation calculation
        let a = tkhdData.subdata(in: matrixOffset..<matrixOffset + 4).withUnsafeBytes {
            Double(Int32(bigEndian: $0.load(as: Int32.self))) / 65536.0
        }
        let b = tkhdData.subdata(in: matrixOffset + 4..<matrixOffset + 8).withUnsafeBytes {
            Double(Int32(bigEndian: $0.load(as: Int32.self))) / 65536.0
        }

        guard a != 0 || b != 0 else {
            logger.debug("Track \(trackIndex) matrix elements a and b are both zero")
            return nil
        }

        let angleRadians = atan2(b, a)
        var angleDegrees = angleRadians * 180.0 / Double.pi

        // Normalize to 0-360 range
        if angleDegrees < 0 {
            angleDegrees += 360
        }

        // Round to nearest common rotation angle (0, 90, 180, 270)
        let commonRotations = [0.0, 90.0, 180.0, 270.0]
        let roundedAngle =
            commonRotations.min(by: { abs($0 - angleDegrees) < abs($1 - angleDegrees) })
            ?? round(angleDegrees)

        logger.debug(
            "Track \(trackIndex) calculated rotation: \(angleDegrees)° (rounded: \(roundedAngle)°)")
        return roundedAngle
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

    /// Prepare first frame info without reading actual data
    private func prepareFirstFrameInfo(videoTrackInfo: VideoTrackInfo) async throws -> Mp4ImageInfo?
    {
        logger.debug("Preparing first frame extraction info")

        // Find the media data offset for the first frame
        guard let firstFrameOffset = try await findFirstFrameOffset(trackInfo: videoTrackInfo)
        else {
            logger.error("Could not locate first frame")
            return nil
        }

        // Get the first frame size without reading the data
        guard let frameSize = try await getFirstFrameSize(trackInfo: videoTrackInfo)
        else {
            logger.error("Could not get first frame size")
            return nil
        }

        logger.debug("Prepared first frame info: offset=\(firstFrameOffset), size=\(frameSize)")

        return Mp4ImageInfo(
            width: videoTrackInfo.width,
            height: videoTrackInfo.height,
            rotation: videoTrackInfo.rotation,
            embeddedData: nil,
            frameOffset: firstFrameOffset,
            frameSize: frameSize,
            videoTrackInfo: videoTrackInfo
        )
    }

    /// Find the offset of the first video frame
    private func findFirstFrameOffset(trackInfo: VideoTrackInfo) async throws -> UInt64? {
        // Look for stco (chunk offset) or co64 (64-bit chunk offset)
        var chunkOffset: UInt64?

        if let stcoData = findBoxData(in: trackInfo.stblData, boxType: "stco"),
            stcoData.count >= 8
        {
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
            co64Data.count >= 8
        {
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

    /// Get the first frame size without reading data
    private func getFirstFrameSize(trackInfo: VideoTrackInfo) async throws -> UInt32? {
        // Look for sample size information in stsz box
        guard let stszData = findBoxData(in: trackInfo.stblData, boxType: "stsz"),
            stszData.count >= 12
        else {
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

        logger.debug("First frame size: \(frameSize)")
        return frameSize
    }

    /// Convert HEVC frame data to HEIC format
    private func convertHevcFrameToHeic(frameData: Data, trackInfo: VideoTrackInfo) async throws
        -> Data?
    {
        logger.debug("Converting HEVC frame to HEIC, frame size: \(frameData.count)")

        // For HEIC format, we need to use the original length-prefixed format
        // but ensure parameter sets are included in the HEVC configuration
        let hevcData = frameData

        logger.debug("Using original HEVC frame data for HEIC, size: \(hevcData.count)")

        // Create a basic HEIC container for the HEVC frame
        let thumbnail = HeifThumbnailEntry(
            itemId: 1,
            offset: 0,
            size: UInt32(hevcData.count),
            rotation: trackInfo.rotation.map { Int($0) },
            width: trackInfo.width,
            height: trackInfo.height,
            type: "hvc1",
            properties: createBasicHevcProperties(
                width: trackInfo.width, height: trackInfo.height, hevcConfig: trackInfo.hevcConfig,
                rotation: trackInfo.rotation)
        )

        logger.debug("Creating HEIC container for \(trackInfo.width)x\(trackInfo.height) image")
        let heicData = try await createHEICFromHEVC(thumbnail, hevcData: hevcData)

        if let heicData = heicData {
            logger.debug("Successfully created HEIC data, size: \(heicData.count)")
        } else {
            logger.error("Failed to create HEIC data")
        }

        return heicData
    }

    /// Extract HEVC configuration from sample description table
    private func extractHevcConfig(from stblData: Data) -> Data? {
        // Look for sample description (stsd) box
        guard let stsdData = findBoxData(in: stblData, boxType: "stsd"),
            stsdData.count >= 16
        else {
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
        let codecType =
            String(data: stsdData.subdata(in: entryOffset + 4..<entryOffset + 8), encoding: .ascii)
            ?? ""
        logger.debug("Found codec type: '\(codecType)', entry size: \(entrySize)")

        // Log some bytes for debugging
        if stsdData.count > entryOffset + 16 {
            let debugBytes = stsdData.subdata(
                in: entryOffset..<min(entryOffset + 16, stsdData.count))
            let hexString = debugBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            logger.debug("Sample entry header bytes: \(hexString)")
        }

        guard codecType == "hvc1" || codecType == "hev1" else {
            logger.error("Not an HEVC codec: '\(codecType)'")
            return nil
        }

        // The sample entry data starts from entryOffset and has size entrySize
        let sampleEntryData = stsdData.subdata(
            in: entryOffset..<min(entryOffset + Int(entrySize), stsdData.count))

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
        let extensionData = sampleEntryData.subdata(
            in: videoSampleEntrySize..<sampleEntryData.count)
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
    private func createBasicHevcProperties(
        width: UInt32, height: UInt32, hevcConfig: Data?, rotation: Double?
    )
        -> [ItemProperty]
    {
        var properties: [ItemProperty] = []
        var propertyIndex: UInt32 = 1

        // Image spatial extents property (ispe)
        var ispeData = Data()
        ispeData.append(0)  // version = 0
        ispeData.append(0)  // flags[0]
        ispeData.append(0)  // flags[1]
        ispeData.append(0)  // flags[2]
        ispeData.append(contentsOf: withUnsafeBytes(of: width.bigEndian) { Data($0) })
        ispeData.append(contentsOf: withUnsafeBytes(of: height.bigEndian) { Data($0) })
        properties.append(
            ItemProperty(
                propertyIndex: propertyIndex,
                propertyType: "ispe",
                rotation: nil,
                width: width,
                height: height,
                rawData: ispeData
            ))
        propertyIndex += 1

        // HEVC configuration property (hvcC)
        let hvcCData: Data
        if let hevcConfig = hevcConfig, hevcConfig.count > 0 {
            // Use extracted HEVC configuration
            logger.debug("Using extracted HEVC config, size: \(hevcConfig.count)")
            hvcCData = hevcConfig
        } else {
            // Fallback to minimal HEVC configuration
            logger.warning("No HEVC config found, using fallback configuration")
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
                0x00,  // numOfArrays (no parameter sets)
            ])
        }

        properties.append(
            ItemProperty(
                propertyIndex: propertyIndex,
                propertyType: "hvcC",
                rotation: nil,
                width: nil,
                height: nil,
                rawData: hvcCData
            ))
        propertyIndex += 1

        // Add rotation property (irot) if rotation is specified
        if let rotation = rotation, rotation != 0.0 {
            logger.debug("Adding rotation property: \(rotation)°")

            // Convert rotation angle to HEIF irot format
            // HEIF irot property format: 1 byte with rotation in 90-degree increments
            // 0 = 0°, 1 = 90° CCW, 2 = 180°, 3 = 270° CCW (90° CW)
            // QuickTime rotation is clockwise, HEIF irot is counter-clockwise
            // So we need to convert: CW 90° -> CCW 270° (irot=3), CW 270° -> CCW 90° (irot=1)
            let normalizedRotation = Int(rotation) % 360
            let irotValue: UInt8
            switch normalizedRotation {
            case 90:
                irotValue = 3  // CW 90° -> CCW 270°
            case 180:
                irotValue = 2  // 180° is same in both directions
            case 270:
                irotValue = 1  // CW 270° -> CCW 90°
            default:
                irotValue = 0  // 0° or unsupported angle
            }

            var irotData = Data()
            irotData.append(irotValue)

            properties.append(
                ItemProperty(
                    propertyIndex: propertyIndex,
                    propertyType: "irot",
                    rotation: Int(rotation),
                    width: nil,
                    height: nil,
                    rawData: irotData
                ))
            propertyIndex += 1
        }

        return properties
    }
}

// MARK: - MP4 Data Structures

private struct Mp4ImageInfo {
    let width: UInt32?
    let height: UInt32?
    let rotation: Double?
    // For embedded thumbnails
    let embeddedData: Data?
    // For first frame extraction
    let frameOffset: UInt64?
    let frameSize: UInt32?
    let videoTrackInfo: VideoTrackInfo?
}

private struct VideoTrackInfo {
    let width: UInt32
    let height: UInt32
    let stblData: Data
    let hevcConfig: Data?
    let rotation: Double?
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

private func parseIlstBox(data: Data, rotation: Double?) -> [Mp4ImageInfo] {
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
                "Item #\(itemCount): name='\(itemName, privacy: .public)', size=\(itemSize), offset=\(offset)"
            )
        }

        if itemName == "covr" {
            // Cover Art
            logger.debug("Processing Cover Art item")
            if let imageData = extractImageFromItem(data: itemData, rotation: rotation) {
                imageInfos.append(imageData)
                logger.debug("Added Cover Art: \(imageData.width ?? 0)x\(imageData.height ?? 0)")
            }
        } else if itemName == "snal" {
            // PreviewImage
            logger.debug("Processing PreviewImage item")
            if let imageData = extractImageFromItem(data: itemData, rotation: rotation) {
                imageInfos.append(imageData)
                logger.debug("Added PreviewImage: \(imageData.width ?? 0)x\(imageData.height ?? 0)")
            }
        } else if itemName == "tnal" {
            // ThumbnailImage
            logger.debug("Processing ThumbnailImage item")
            if let imageData = extractImageFromItem(data: itemData, rotation: rotation) {
                imageInfos.append(imageData)
                logger.debug(
                    "Added ThumbnailImage: \(imageData.width ?? 0)x\(imageData.height ?? 0)")
            }
        }

        offset += UInt64(itemSize)
    }

    return imageInfos
}

private func extractImageFromItem(data: Data, rotation: Double?) -> Mp4ImageInfo? {
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
                return Mp4ImageInfo(
                    width: width,
                    height: height,
                    rotation: rotation,
                    embeddedData: imageData,
                    frameOffset: nil,
                    frameSize: nil,
                    videoTrackInfo: nil
                )
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

private func parseUdtaForThumbnails(data: Data, rotation: Double?) -> [Mp4ImageInfo] {
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
            if let thumbnailData = extractThumbnailFromBox(data: boxData, rotation: rotation) {
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

private func extractThumbnailFromBox(data: Data, rotation: Double?) -> Mp4ImageInfo? {
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
                    return Mp4ImageInfo(
                        width: width,
                        height: height,
                        rotation: rotation,
                        embeddedData: finalJpegData,
                        frameOffset: nil,
                        frameSize: nil,
                        videoTrackInfo: nil
                    )
                }
            }

            // 如果没有找到结束标记，使用剩余数据
            logger.debug("No JPEG end marker found, using remaining data")
            let (width, height) = extractJpegDimensions(data: jpegData)
            return Mp4ImageInfo(
                width: width,
                height: height,
                rotation: rotation,
                embeddedData: jpegData,
                frameOffset: nil,
                frameSize: nil,
                videoTrackInfo: nil
            )
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
