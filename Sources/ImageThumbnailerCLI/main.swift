import ArgumentParser
import Foundation
import ImageThumbnailer
import OSLog

private let logger = Logger(subsystem: "com.wangrunji.ImageThumbnailer", category: "CLI")

@main
struct ImageThumbnailCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ImageThumbnailCLI",
        abstract:
            "A tool to generate thumbnails from various image formats including HEIF, JPEG, and Sony ARW files."
    )

    @Argument(help: "The path to the image file (HEIF, JPEG, or Sony ARW)")
    var imagePath: String

    @Option(name: .shortAndLong, help: "The length of the thumbnail's short side")
    var shortSideLength: UInt32?

    @Option(name: .shortAndLong, help: "The index of the thumbnail to extract")
    var thumbnailIndex: Int?

    @Option(name: .shortAndLong, help: "The output path for the thumbnail")
    var outputPath: String?

    func run() async throws {
        do {
            let fileURL = URL(fileURLWithPath: imagePath)
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer { fileHandle.closeFile() }

            logger.info("extracting thumbnail from \(imagePath)...")

            // create read function
            var readCount = 0
            var readBytes = 0
            let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
                readCount += 1
                readBytes += Int(length)
                try fileHandle.seek(toOffset: offset)
                let data = fileHandle.readData(ofLength: Int(length))
                if data.count < Int(length) {
                    logger.error("fail to read data at offset \(offset), length \(length)")
                    throw NSError(
                        domain: "ImageError", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "fail to read file data"]
                    )
                }
                logger.debug(
                    "read data: offset=\(offset), length=\(length), data=\(data.count) bytes")
                return data
            }

            // Determine file type and extract thumbnail accordingly
            let fileExtension = fileURL.pathExtension.lowercased()

            let reader: ImageReader
            switch fileExtension {
            case "heic", "heif", "hif":
                reader = HeifReader(readAt: readAt)
            case "jpg", "jpeg":
                reader = JpegReader(readAt: readAt)
            case "arw":
                reader = SonyArwReader(readAt: readAt)
            case "mp4":
                reader = Mp4Reader(readAt: readAt)
            default:
                logger.error(
                    "unsupported file format: \(fileExtension). Only HEIF, JPEG, ARW, and MP4 are supported."
                )
                return
            }

            let metadata = try await reader.getMetadata()
            logger.info("metadata: size: \(metadata.width)x\(metadata.height)")
            if let duration = metadata.duration {
                logger.info("duration: \(duration) seconds")
            }

            let thumbnailList = try await reader.getThumbnailList()
            if thumbnailList.isEmpty {
                logger.error("no thumbnail found in file")
                return
            }

            // 显示所有找到的缩略图
            logger.info("found \(thumbnailList.count) thumbnails:")
            for (i, info) in thumbnailList.enumerated() {
                logger.info(
                    "  [\(i)] format: \(info.format, privacy: .public), size: \(info.size) bytes, dimensions: \(info.width ?? 0)x\(info.height ?? 0), rotation: \(info.rotation ?? 0)"
                )
            }

            let index: Int
            if let thumbnailIndex = thumbnailIndex {
                index = thumbnailIndex
            } else {
                var indices = Array(0..<thumbnailList.count)
                indices.sort { thumbnailList[$0].width ?? 0 < thumbnailList[$1].width ?? 0 }
                index =
                    indices.first(where: { thumbnailList[$0].width ?? 0 >= shortSideLength ?? 0 })
                    ?? 0
            }
            let info = thumbnailList[index]
            let thumbnail = try await reader.getThumbnail(at: index)
            logger.info("selected thumbnail index: \(index)")

            // save thumbnail data
            let outputURL = URL(fileURLWithPath: outputPath ?? "thumbnail.\(info.format)")
            try thumbnail.write(to: outputURL)
            logger.info("thumbnail saved to: \(outputURL.path)")
            logger.info("read count: \(readCount), bytes: \(readBytes)")
        } catch {
            logger.error("\(error.localizedDescription)")
        }
    }
}
