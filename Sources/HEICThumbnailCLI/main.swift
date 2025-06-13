import Foundation
import HEICThumbnailExtractor
import Logging

private let logger = Logger(label: "com.hdremote.HEICThumbnailCLI")

@main
struct HEICThumbnailCLI {
    static func main() async {
        guard CommandLine.arguments.count > 1 else {
            print("Usage: HEICThumbnailCLI <HEIC file path> [output path]")
            print("Example: HEICThumbnailCLI input.heic output.jpg")
            return
        }

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

        let inputPath = CommandLine.arguments[1]
        let outputPath =
            CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "thumbnail.jpg"

        do {
            let fileURL = URL(fileURLWithPath: inputPath)
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer { fileHandle.closeFile() }

            logger.info("extracting thumbnail from \(inputPath)...")

            // create read function
            let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
                try fileHandle.seek(toOffset: offset)
                let data = fileHandle.readData(ofLength: Int(length))
                if data.isEmpty && length > 0 {
                    throw NSError(
                        domain: "HEICError", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "fail to read file data"])
                }
                logger.debug(
                    "read data: offset=\(offset), length=\(length), data=\(data.count) bytes")
                return data
            }

            // extract thumbnail data
            if let thumbnailData = try await readHEICThumbnail(readAt: readAt) {
                logger.info("success to extract thumbnail, size: \(thumbnailData.count) bytes")

                // save thumbnail data
                let outputURL = URL(fileURLWithPath: outputPath)
                try thumbnailData.write(to: outputURL)
                logger.info("thumbnail saved to: \(outputPath)")

                // try to create image object to validate
                if let image = createImageFromThumbnailData(thumbnailData) {
                    #if canImport(UIKit)
                        logger.info("image size: \(image.size.width) x \(image.size.height)")
                    #elseif canImport(AppKit)
                        logger.info("image size: \(image.size.width) x \(image.size.height)")
                    #endif
                } else {
                    logger.warning("fail to create image from thumbnail data")
                }
            } else {
                logger.error("fail to extract thumbnail from file")
            }

        } catch {
            logger.error("\(error.localizedDescription)")
        }
    }
}
