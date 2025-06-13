import ArgumentParser
import Foundation
import HEICThumbnailExtractor
import Logging

private let logger = Logger(label: "com.hdremote.HEICThumbnailCLI")

@main
struct HEICThumbnailCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "HEICThumbnailCLI",
        abstract: "A tool to generate thumbnails from HEIC images."
    )

    @Argument(help: "The path to the HEIC file")
    var heicFilePath: String

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
            let fileURL = URL(fileURLWithPath: heicFilePath)
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer { fileHandle.closeFile() }

            logger.info("extracting thumbnail from \(heicFilePath)...")

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
            if let thumbnailData = try await readHEICThumbnail(
                readAt: readAt, minShortSide: shortSideLength
            ) {
                logger.info("success to extract thumbnail, size: \(thumbnailData.count) bytes")

                // save thumbnail data
                let outputURL = URL(fileURLWithPath: outputPath ?? "thumbnail.jpg")
                try thumbnailData.write(to: outputURL)
                logger.info("thumbnail saved to: \(outputURL.path)")

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
