import Foundation

/// HEIC file writer that builds HEIC data incrementally in a buffer
class HEICWriter {
    private var buffer = Data()

    /// Create a complete HEIC file from HEVC data
    func createHEICFromHEVC(_ thumbnail: HeifThumbnailEntry, hevcData: Data) -> Data {
        buffer.removeAll()

        // Build HEIC structure
        writeFtypBox()
        let mdatOffsetPosition = writeMetaBox(for: thumbnail)

        // Update extent location to point to mdat box start
        let mdatOffset = UInt32(buffer.count + 8)
        updateMdatLocation(
            at: mdatOffsetPosition, offset: mdatOffset, length: UInt32(hevcData.count)
        )

        writeMdatBox(with: hevcData)
        return buffer
    }

    // MARK: - Box Writing Methods

    private func writeFtypBox() {
        let startPosition = buffer.count
        writeUInt32(0) // Size placeholder
        writeString("ftyp")
        writeString("heic") // Major brand
        writeUInt32(0) // Minor version
        writeString("mif1") // Compatible brands
        writeString("heic")
        updateBoxSize(at: startPosition)
    }

    private func writeMetaBox(for thumbnail: HeifThumbnailEntry) -> Int {
        let startPosition = buffer.count
        writeUInt32(0) // Size placeholder
        writeString("meta")
        writeUInt32(0) // Version and flags

        writeHdlrBox()
        writePitmBox(itemId: 1)
        writeIinfBox(for: thumbnail)
        writeIprpBox(for: thumbnail)
        let mdatOffsetPosition = writeIlocBox(itemId: 1)

        updateBoxSize(at: startPosition)
        return mdatOffsetPosition
    }

    private func writeHdlrBox() {
        let startPosition = buffer.count
        writeUInt32(0) // Size placeholder
        writeString("hdlr")
        writeUInt32(0) // Version and flags
        writeUInt32(0) // Pre-defined
        writeString("pict") // Handler type
        writeUInt32(0) // Reserved
        writeUInt32(0)
        writeUInt32(0)
        writeUInt8(0) // Name (empty)
        updateBoxSize(at: startPosition)
    }

    private func writePitmBox(itemId: UInt32) {
        let startPosition = buffer.count
        writeUInt32(0) // Size placeholder
        writeString("pitm")
        writeUInt32(0) // Version and flags
        writeUInt16(UInt16(itemId)) // Item ID
        updateBoxSize(at: startPosition)
    }

    private func writeIinfBox(for thumbnail: HeifThumbnailEntry) {
        let startPosition = buffer.count
        writeUInt32(0) // Size placeholder
        writeString("iinf")
        writeUInt32(0) // Version and flags
        writeUInt16(1) // Entry count
        writeInfeBox(itemId: 1, itemType: thumbnail.type)
        updateBoxSize(at: startPosition)
    }

    private func writeInfeBox(itemId: UInt32, itemType: String) {
        let startPosition = buffer.count
        writeUInt32(0) // Size placeholder
        writeString("infe")
        writeBytes([0x02, 0x00, 0x00, 0x00]) // Version 2, flags 0
        writeUInt16(UInt16(itemId)) // Item ID
        writeUInt16(0) // Item protection index

        assert(itemType.count == 4, "Item type must be 4 bytes")
        writeString(itemType) // Item type
        writeUInt8(0) // Item name (empty)
        updateBoxSize(at: startPosition)
    }

    private func writeIprpBox(for thumbnail: HeifThumbnailEntry) {
        let startPosition = buffer.count
        writeUInt32(0) // Size placeholder
        writeString("iprp")
        writeIpcoBox(for: thumbnail)
        writeIpmaBox(for: thumbnail)
        updateBoxSize(at: startPosition)
    }

    private func writeIpcoBox(for thumbnail: HeifThumbnailEntry) {
        let startPosition = buffer.count
        writeUInt32(0) // Size placeholder
        writeString("ipco")

        // Add properties from thumbnail
        for property in thumbnail.properties {
            writePropertyBox(property: property)
        }

        updateBoxSize(at: startPosition)
    }

    private func writePropertyBox(property: ItemProperty) {
        let startPosition = buffer.count
        writeUInt32(0) // Size placeholder
        writeString(property.propertyType)
        writeData(property.rawData)
        updateBoxSize(at: startPosition)
    }

    private func writeIpmaBox(for thumbnail: HeifThumbnailEntry) {
        let startPosition = buffer.count
        writeUInt32(0) // Size placeholder
        writeString("ipma")
        writeUInt32(0) // Version and flags
        writeUInt32(1) // Entry count
        writeUInt16(1) // Item ID
        writeUInt8(UInt8(thumbnail.properties.count)) // Association count

        // Property associations
        for (index, _) in thumbnail.properties.enumerated() {
            writeUInt8(UInt8(index + 1) | 0x80) // Property index with essential flag
        }

        updateBoxSize(at: startPosition)
    }

    private func writeIlocBox(itemId: UInt32) -> Int {
        let startPosition = buffer.count
        writeUInt32(0) // Size placeholder
        writeString("iloc")
        writeBytes([0x01, 0x00, 0x00, 0x00]) // Version 1, flags 0
        writeBytes([0x44, 0x00]) // offset_size=4, length_size=4, base_offset_size=0, index_size=0
        writeUInt16(1) // Item count
        writeUInt16(UInt16(itemId)) // Item ID
        writeUInt16(0) // Construction method
        writeUInt16(0) // Data reference index
        writeUInt16(1) // Extent count

        // Extent offset and length (placeholder - updated later)
        let mdatOffsetPosition = buffer.count
        writeUInt32(0)
        writeUInt32(0)

        updateBoxSize(at: startPosition)
        return mdatOffsetPosition
    }

    private func writeMdatBox(with hevcData: Data) {
        writeUInt32(UInt32(hevcData.count + 8)) // Box size
        writeString("mdat") // Box type
        writeData(hevcData) // HEVC data
    }

    // MARK: - Helper Methods

    private func writeUInt32(_ value: UInt32) {
        var bigEndianValue = value.bigEndian
        buffer.append(Data(bytes: &bigEndianValue, count: 4))
    }

    private func writeUInt16(_ value: UInt16) {
        var bigEndianValue = value.bigEndian
        buffer.append(Data(bytes: &bigEndianValue, count: 2))
    }

    private func writeUInt8(_ value: UInt8) {
        buffer.append(value)
    }

    private func writeString(_ string: String) {
        if let data = string.data(using: .ascii) {
            buffer.append(data)
        }
    }

    private func writeData(_ data: Data) {
        buffer.append(data)
    }

    private func writeBytes(_ bytes: [UInt8]) {
        buffer.append(Data(bytes))
    }

    private func updateBoxSize(at position: Int) {
        let boxSize = UInt32(buffer.count - position)
        var bigEndianSize = boxSize.bigEndian
        buffer.replaceSubrange(position ..< position + 4, with: Data(bytes: &bigEndianSize, count: 4))
    }

    private func updateMdatLocation(at position: Int, offset: UInt32, length: UInt32) {
        var bigEndianOffset = offset.bigEndian
        buffer.replaceSubrange(
            position ..< position + 4, with: Data(bytes: &bigEndianOffset, count: 4)
        )
        var bigEndianLength = length.bigEndian
        buffer.replaceSubrange(
            position + 4 ..< position + 8, with: Data(bytes: &bigEndianLength, count: 4)
        )
    }
}

/// Wrap HEVC data as a complete HEIC file
func createHEICFromHEVC(_ thumbnail: HeifThumbnailEntry, hevcData: Data) async throws -> Data? {
    let writer = HEICWriter()
    return writer.createHEICFromHEVC(thumbnail, hevcData: hevcData)
}
