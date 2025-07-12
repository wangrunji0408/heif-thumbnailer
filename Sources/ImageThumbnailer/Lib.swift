import Foundation

public protocol ImageReader {
    init(readAt: @escaping (UInt64, UInt32) async throws -> Data)
    func getThumbnailList() async throws -> [ThumbnailInfo]
    func getThumbnail(at index: Int) async throws -> Data
    func getMetadata() async throws -> Metadata
}

public struct ThumbnailInfo {
    public let size: UInt32
    public let format: String
    public let width: UInt32?
    public let height: UInt32?
    public let rotation: Int?
}

public struct Metadata {
    public let width: UInt32
    public let height: UInt32
}
