import Foundation
import ImageIO

#if canImport(UIKit)
    import UIKit

    public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
    import AppKit

    public typealias PlatformImage = NSImage
#endif

public struct Thumbnail {
    public let data: Data
    public let format: FileFormat
    public let width: UInt32?
    public let height: UInt32?
    public let rotation: Int
}

public enum FileFormat {
    case heic
    case jpeg
    case arw
}

/// Efficiently read thumbnail from a HEIC file with minimal read operations
/// - Parameters:
///   - readAt: Async function to read data at specific offset and length
///   - minShortSide: Minimum short side length in pixels. Returns the smallest thumbnail that meets this requirement. If nil, returns the first available thumbnail.
/// - Returns: Thumbnail data with metadata, or nil if extraction fails
public func readThumbnail(
    readAt: @escaping (UInt64, UInt32) async throws -> Data,
    type: FileFormat,
    minShortSide: UInt32? = nil
) async throws -> Thumbnail? {
    switch type {
    case .heic:
        return try await readHeifThumbnail(readAt: readAt, minShortSide: minShortSide)
    case .jpeg:
        return try await readJpegThumbnail(readAt: readAt, minShortSide: minShortSide)
    case .arw:
        return try await readSonyArwThumbnail(readAt: readAt, minShortSide: minShortSide)
    }
}

// MARK: - Image Creation

/// Create a platform image from thumbnail data
public func createImageFromThumbnailData(_ thumbnailData: Data) -> PlatformImage? {
    createImageFromThumbnailData(thumbnailData, rotation: 0)
}

/// Create a platform image from thumbnail data with rotation
public func createImageFromThumbnailData(_ thumbnailData: Data, rotation: Int) -> PlatformImage? {
    guard let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else {
        return nil
    }

    let finalImage = (rotation == 0) ? cgImage : rotateCGImage(cgImage, by: rotation)

    #if canImport(UIKit)
        return UIImage(cgImage: finalImage)
    #elseif canImport(AppKit)
        return NSImage(
            cgImage: finalImage, size: NSSize(width: finalImage.width, height: finalImage.height)
        )
    #endif
}

private func rotateCGImage(_ image: CGImage, by degrees: Int) -> CGImage {
    let normalizedDegrees = ((degrees % 360) + 360) % 360
    guard normalizedDegrees != 0 else { return image }

    let (width, height) = (image.width, image.height)
    let (newWidth, newHeight) =
        (normalizedDegrees == 90 || normalizedDegrees == 270) ? (height, width) : (width, height)

    guard let colorSpace = image.colorSpace,
          let context = CGContext(
              data: nil, width: newWidth, height: newHeight,
              bitsPerComponent: image.bitsPerComponent, bytesPerRow: 0,
              space: colorSpace, bitmapInfo: image.bitmapInfo.rawValue
          )
    else {
        return image
    }

    context.translateBy(x: CGFloat(newWidth) / 2, y: CGFloat(newHeight) / 2)
    context.rotate(by: CGFloat(normalizedDegrees) * .pi / 180)
    context.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    return context.makeImage() ?? image
}
