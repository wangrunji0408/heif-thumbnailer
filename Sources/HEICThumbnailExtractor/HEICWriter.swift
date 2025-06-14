import Foundation

/// HEIC file writer that builds HEIC data incrementally in a buffer
class HEICWriter {
    private var buffer = Data()

    /// Create a complete HEIC file from HEVC data
    func createHEICFromHEVC(_ thumbnail: ThumbnailInfo, hevcData: Data) -> Data {
        buffer.removeAll()

        // 1. Create ftyp box
        writeFtypBox()

        // 2. Create meta box and get mdat offset position
        let mdatOffsetPosition = writeMetaBox(for: thumbnail)

        // 3. Update extent location to point to mdat box start
        let mdatOffset = UInt32(buffer.count + 8)
        updateMdatLocation(
            at: mdatOffsetPosition, offset: mdatOffset, length: UInt32(hevcData.count))

        // 4. Create mdat box with HEVC data
        writeMdatBox(with: hevcData)

        return buffer
    }

    // MARK: - Private Box Writing Methods

    /// Write ftyp box for HEIC file
    private func writeFtypBox() {
        let startPosition = buffer.count

        // Box size placeholder
        writeUInt32(0)

        // Box type
        writeString("ftyp")

        // Major brand
        writeString("heic")

        // Minor version
        writeUInt32(0)

        // Compatible brands
        writeString("mif1")
        writeString("heic")

        // Update box size
        updateBoxSize(at: startPosition)
    }

    /// Write meta box for thumbnail and return the position where mdat offset should be updated
    private func writeMetaBox(for thumbnail: ThumbnailInfo) -> Int {
        let startPosition = buffer.count

        // Box size placeholder
        writeUInt32(0)

        // Box type
        writeString("meta")

        // Version and flags
        writeUInt32(0)

        // hdlr box
        writeHdlrBox()

        // pitm box
        writePitmBox(itemId: 1)

        // iinf box
        writeIinfBox(for: thumbnail)

        // iprp box
        writeIprpBox(for: thumbnail)

        // iloc box
        let mdatOffsetPosition = writeIlocBox(itemId: 1)

        // Update box size
        updateBoxSize(at: startPosition)

        return mdatOffsetPosition
    }

    /// Write hdlr box
    private func writeHdlrBox() {
        let startPosition = buffer.count

        // Box size placeholder
        writeUInt32(0)

        // Box type
        writeString("hdlr")

        // Version and flags
        writeUInt32(0)

        // Pre-defined
        writeUInt32(0)

        // Handler type
        writeString("pict")

        // Reserved
        writeUInt32(0)
        writeUInt32(0)
        writeUInt32(0)

        // Name (empty)
        writeUInt8(0)

        // Update box size
        updateBoxSize(at: startPosition)
    }

    /// Write pitm box
    private func writePitmBox(itemId: UInt32) {
        let startPosition = buffer.count

        // Box size placeholder
        writeUInt32(0)

        // Box type
        writeString("pitm")

        // Version and flags
        writeUInt32(0)

        // Item ID
        writeUInt16(UInt16(itemId))

        // Update box size
        updateBoxSize(at: startPosition)
    }

    /// Write iinf box
    private func writeIinfBox(for thumbnail: ThumbnailInfo) {
        let startPosition = buffer.count

        // Box size placeholder
        writeUInt32(0)

        // Box type
        writeString("iinf")

        // Version and flags
        writeUInt32(0)

        // Entry count
        writeUInt16(1)

        // infe box
        writeInfeBox(itemId: 1, itemType: thumbnail.type)

        // Update box size
        updateBoxSize(at: startPosition)
    }

    /// Write infe box
    private func writeInfeBox(itemId: UInt32, itemType: String) {
        let startPosition = buffer.count

        // Box size placeholder
        writeUInt32(0)

        // Box type
        writeString("infe")

        // Version and flags (version 2, flags 0x000000 for main image)
        writeBytes([0x02, 0x00, 0x00, 0x00])

        // Item ID
        writeUInt16(UInt16(itemId))

        // Item protection index
        writeUInt16(0)

        // Item type
        assert(itemType.count == 4, "Item type must be 4 bytes")
        writeString(itemType)

        // Item name (empty)
        writeUInt8(0)

        // Update box size
        updateBoxSize(at: startPosition)
    }

    /// Write iprp box
    private func writeIprpBox(for thumbnail: ThumbnailInfo) {
        let startPosition = buffer.count

        // Box size placeholder
        writeUInt32(0)

        // Box type
        writeString("iprp")

        // ipco box
        writeIpcoBox(for: thumbnail)

        // ipma box
        writeIpmaBox(for: thumbnail)

        // Update box size
        updateBoxSize(at: startPosition)
    }

    /// Write ipco box
    private func writeIpcoBox(for thumbnail: ThumbnailInfo) {
        let startPosition = buffer.count

        // Box size placeholder
        writeUInt32(0)

        // Box type
        writeString("ipco")

        // Add properties from thumbnail
        for property in thumbnail.properties {
            writePropertyBox(property: property)
        }

        // Update box size
        updateBoxSize(at: startPosition)
    }

    /// Write property box from ItemProperty
    private func writePropertyBox(property: ItemProperty) {
        let startPosition = buffer.count

        // Box size placeholder
        writeUInt32(0)

        // Box type
        writeString(property.propertyType)

        // Property data
        writeData(property.rawData)

        // Update box size
        updateBoxSize(at: startPosition)
    }

    /// Write ipma box
    private func writeIpmaBox(for thumbnail: ThumbnailInfo) {
        let startPosition = buffer.count

        // Box size placeholder
        writeUInt32(0)

        // Box type
        writeString("ipma")

        // Version and flags
        writeUInt32(0)

        // Entry count
        writeUInt32(1)

        // Item ID
        writeUInt16(1)

        // Association count
        writeUInt8(UInt8(thumbnail.properties.count))

        // Property associations
        for (index, _) in thumbnail.properties.enumerated() {
            // Property index (1-based) with essential flag
            writeUInt8(UInt8(index + 1) | 0x80)
        }

        // Update box size
        updateBoxSize(at: startPosition)
    }

    /// Write iloc box and return the position where mdat offset should be updated
    private func writeIlocBox(itemId: UInt32) -> Int {
        let startPosition = buffer.count

        // Box size placeholder
        writeUInt32(0)

        // Box type
        writeString("iloc")

        // Version and flags (version 1 to support construction_method)
        writeBytes([0x01, 0x00, 0x00, 0x00])

        // Offset size, length size, base offset size, index size
        writeBytes([0x44, 0x00])  // offset_size=4, length_size=4, base_offset_size=0, index_size=0

        // Item count
        writeUInt16(1)

        // Item ID (16-bit for version 1)
        writeUInt16(UInt16(itemId))

        // Construction method (version >= 1)
        writeUInt16(0)

        // Data reference index
        writeUInt16(0)

        // Extent count
        writeUInt16(1)

        // Extent offset and length (placeholder - this is what we need to update later)
        let mdatOffsetPosition = buffer.count
        writeUInt32(0)
        writeUInt32(0)

        // Update box size
        updateBoxSize(at: startPosition)

        return mdatOffsetPosition
    }

    /// Write mdat box with HEVC data
    private func writeMdatBox(with hevcData: Data) {
        // Box size
        writeUInt32(UInt32(hevcData.count + 8))

        // Box type
        writeString("mdat")

        // HEVC data
        writeData(hevcData)
    }

    // MARK: - Helper Methods

    /// Write a 32-bit unsigned integer in big-endian format
    private func writeUInt32(_ value: UInt32) {
        var bigEndianValue = value.bigEndian
        buffer.append(Data(bytes: &bigEndianValue, count: 4))
    }

    /// Write a 16-bit unsigned integer in big-endian format
    private func writeUInt16(_ value: UInt16) {
        var bigEndianValue = value.bigEndian
        buffer.append(Data(bytes: &bigEndianValue, count: 2))
    }

    /// Write a single byte
    private func writeUInt8(_ value: UInt8) {
        buffer.append(value)
    }

    /// Write a string as ASCII data
    private func writeString(_ string: String) {
        if let data = string.data(using: .ascii) {
            buffer.append(data)
        }
    }

    /// Write raw data
    private func writeData(_ data: Data) {
        buffer.append(data)
    }

    /// Write an array of bytes
    private func writeBytes(_ bytes: [UInt8]) {
        buffer.append(Data(bytes))
    }

    /// Update box size at the specified position
    private func updateBoxSize(at position: Int) {
        let boxSize = UInt32(buffer.count - position)
        var bigEndianSize = boxSize.bigEndian
        buffer.replaceSubrange(position..<position + 4, with: Data(bytes: &bigEndianSize, count: 4))
    }

    /// Update mdat offset at the specified position
    private func updateMdatLocation(at position: Int, offset: UInt32, length: UInt32) {
        var bigEndianOffset = offset.bigEndian
        buffer.replaceSubrange(
            position..<position + 4, with: Data(bytes: &bigEndianOffset, count: 4))
        var bigEndianLength = length.bigEndian
        buffer.replaceSubrange(
            position + 4..<position + 8, with: Data(bytes: &bigEndianLength, count: 4))
    }
}

/// Wrap HEVC data as a complete HEIC file
func createHEICFromHEVC(_ thumbnail: ThumbnailInfo, hevcData: Data) async throws -> Data? {
    let writer = HEICWriter()
    return writer.createHEICFromHEVC(thumbnail, hevcData: hevcData)
}
