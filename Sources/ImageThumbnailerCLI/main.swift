import ArgumentParser
import Foundation
import ImageThumbnailer
import Logging

private let logger = Logger(label: "com.hdremote.ImageThumbnailCLI")

@main
struct ImageThumbnailCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ImageThumbnailCLI",
        abstract: "A tool to generate thumbnails from various image formats including HEIF, JPEG, and Sony ARW files."
    )

    @Argument(help: "The path to the image file (HEIF, JPEG, or Sony ARW)")
    var imagePath: String

    @Option(name: .shortAndLong, help: "The length of the thumbnail's short side")
    var shortSideLength: UInt32?

    @Option(name: .shortAndLong, help: "The output path for the thumbnail")
    var outputPath: String?

    func run() async throws {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)

            if let logLevel = Logger.Level(
                rawValue: ProcessInfo.processInfo.environment["LOG_LEVEL"]?.lowercased() ?? "")
            {
                handler.logLevel = logLevel
            } else {
                // default level
                handler.logLevel = .info
            }

            return handler
        }

        do {
            let fileURL = URL(fileURLWithPath: imagePath)
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer { fileHandle.closeFile() }

            logger.info("extracting thumbnail from \(imagePath)...")

            // create read function
            let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
                try fileHandle.seek(toOffset: offset)
                let data = fileHandle.readData(ofLength: Int(length))
                if data.isEmpty, length > 0 {
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
                logger.error("unsupported file format: \(fileExtension). Only HEIF, JPEG, ARW, and MP4 are supported.")
                return
            }

            let thumbnailList = try await reader.getThumbnailList()
            if thumbnailList.isEmpty {
                logger.error("no thumbnail found in file")
                return
            }
            var indices = Array(0 ..< thumbnailList.count)
            indices.sort { thumbnailList[$0].width ?? 0 < thumbnailList[$1].width ?? 0 }
            let index = indices.first(where: { thumbnailList[$0].width ?? 0 >= shortSideLength ?? 0 }) ?? 0
            let info = thumbnailList[index]
            let thumbnail = try await reader.getThumbnail(at: index)
            logger.info("thumbnail index: \(index), format: \(info.format), size: \(info.size) bytes, width: \(info.width ?? 0), height: \(info.height ?? 0), rotation: \(info.rotation ?? 0)")

            // save thumbnail data
            let outputURL = URL(fileURLWithPath: outputPath ?? "thumbnail.\(info.format)")
            try thumbnail.write(to: outputURL)
            logger.info("thumbnail saved to: \(outputURL.path)")
        } catch {
            logger.error("\(error.localizedDescription)")
        }
    }
}
