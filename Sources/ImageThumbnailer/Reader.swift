import Foundation

class Reader {
    private let readAt: (UInt64, UInt32) async throws -> Data
    private var buffers: [(UInt64, Data)] = []
    private var byteOrder: ByteOrder = .bigEndian

    init(readAt: @escaping (UInt64, UInt32) async throws -> Data) {
        self.readAt = readAt
    }

    func setByteOrder(_ byteOrder: ByteOrder) {
        self.byteOrder = byteOrder
    }

    func read(at offset: UInt64, length: UInt32) async throws -> Data {
        for (bufferOffset, buffer) in buffers {
            if offset >= bufferOffset, offset + UInt64(length) <= bufferOffset + UInt64(buffer.count) {
                return buffer.subdata(in: Int(offset - bufferOffset) ..< Int(offset - bufferOffset + UInt64(length)))
            }
        }
        return try await readAt(offset, length)
    }

    func prefetch(at offset: UInt64, length: UInt32) async throws {
        for (bufferOffset, buffer) in buffers {
            if offset >= bufferOffset, offset + UInt64(length) <= bufferOffset + UInt64(buffer.count) {
                return
            }
        }
        let data = try await readAt(offset, length)
        buffers.append((offset, data))
    }

    func readUInt8(at offset: UInt64) async throws -> UInt8 {
        let data = try await read(at: offset, length: 1)
        return data[0]
    }

    func readUInt16(at offset: UInt64, byteOrder: ByteOrder? = nil) async throws -> UInt16 {
        let data = try await read(at: offset, length: 2)
        if byteOrder ?? self.byteOrder == .bigEndian {
            return data.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        } else {
            return data.withUnsafeBytes { $0.load(as: UInt16.self) }
        }
    }

    func readUInt32(at offset: UInt64, byteOrder: ByteOrder? = nil) async throws -> UInt32 {
        let data = try await read(at: offset, length: 4)
        if byteOrder ?? self.byteOrder == .bigEndian {
            return data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        } else {
            return data.withUnsafeBytes { $0.load(as: UInt32.self) }
        }
    }

    func readString(at offset: UInt64, length: UInt32) async throws -> String {
        return try String(data: await read(at: offset, length: length), encoding: .ascii) ?? ""
    }
}

enum ByteOrder {
    case bigEndian
    case littleEndian
}
