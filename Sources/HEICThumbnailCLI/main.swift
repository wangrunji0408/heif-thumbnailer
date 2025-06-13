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
            if let thumbnail = try await readHEICThumbnail(
                readAt: readAt, minShortSide: shortSideLength
            ) {
                logger.info(
                    "success to extract thumbnail, size: \(thumbnail.data.count) bytes, type: \(thumbnail.type), rotation: \(thumbnail.rotation), image size: \(thumbnail.width)x\(thumbnail.height)"
                )

                // save thumbnail data
                let outputURL = URL(fileURLWithPath: outputPath ?? "thumbnail.\(thumbnail.type)")
                try thumbnail.data.write(to: outputURL)
                logger.info("thumbnail saved to: \(outputURL.path)")
            } else {
                logger.error("fail to extract thumbnail from file")
            }

        } catch {
            logger.error("\(error.localizedDescription)")
        }
    }
}
