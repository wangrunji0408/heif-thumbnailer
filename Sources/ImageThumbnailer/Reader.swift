import Foundation

class Reader {
    private let readAt: (UInt64, UInt32) async throws -> Data
    private var buffers: [(UInt64, Data)] = []

    init(readAt: @escaping (UInt64, UInt32) async throws -> Data) {
        self.readAt = readAt
    }

    func readAt(offset: UInt64, length: UInt32) async throws -> Data {
        for (bufferOffset, buffer) in buffers {
            if offset >= bufferOffset, offset + UInt64(length) <= bufferOffset + UInt64(buffer.count) {
                return buffer.subdata(in: Int(offset - bufferOffset) ..< Int(offset - bufferOffset + UInt64(length)))
            }
        }
        return try await readAt(offset, length)
    }

    func prefetch(offset: UInt64, length: UInt32) async throws {
        for (bufferOffset, buffer) in buffers {
            if offset >= bufferOffset, offset + UInt64(length) <= bufferOffset + UInt64(buffer.count) {
                return
            }
        }
        let data = try await readAt(offset, length)
        buffers.append((offset, data))
    }
}
