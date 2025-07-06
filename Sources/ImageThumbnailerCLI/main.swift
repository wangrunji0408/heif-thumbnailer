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

            if fileExtension == "heic" || fileExtension == "heif" {
                // Extract HEIC thumbnail
                if let thumbnail = try await readHeifThumbnail(
                    readAt: readAt, minShortSide: shortSideLength
                ) {
                    logger.info(
                        "success to extract HEIC thumbnail, size: \(thumbnail.data.count) bytes, type: \(thumbnail.type), rotation: \(thumbnail.rotation), image size: \(thumbnail.width)x\(thumbnail.height)"
                    )

                    // save thumbnail data
                    let outputURL = URL(fileURLWithPath: outputPath ?? "thumbnail.\(thumbnail.type)")
                    try thumbnail.data.write(to: outputURL)
                    logger.info("thumbnail saved to: \(outputURL.path)")
                } else {
                    logger.error("fail to extract HEIC thumbnail from file")
                }
            } else if fileExtension == "jpg" || fileExtension == "jpeg" {
                // Extract JPEG thumbnail
                if let thumbnail = try await readJpegThumbnail(
                    readAt: readAt, minShortSide: shortSideLength
                ) {
                    logger.info(
                        "success to extract JPEG thumbnail, size: \(thumbnail.data.count) bytes, type: \(thumbnail.type), image size: \(thumbnail.width)x\(thumbnail.height)"
                    )

                    // save thumbnail data
                    let outputURL = URL(fileURLWithPath: outputPath ?? "thumbnail.jpg")
                    try thumbnail.data.write(to: outputURL)
                    logger.info("thumbnail saved to: \(outputURL.path)")
                } else {
                    logger.error("fail to extract JPEG thumbnail from file")
                }
            } else if fileExtension == "arw" {
                // Extract Sony ARW thumbnail
                if let thumbnail = try await readSonyArwThumbnail(
                    readAt: readAt, minShortSide: shortSideLength
                ) {
                    logger.info("success to extract Sony ARW thumbnail, size: \(thumbnail.data.count) bytes, type: \(thumbnail.type), image size: \(thumbnail.width)x\(thumbnail.height)")

                    // save thumbnail data
                    let outputURL = URL(fileURLWithPath: outputPath ?? "thumbnail.jpg")
                    try thumbnail.data.write(to: outputURL)
                    logger.info("thumbnail saved to: \(outputURL.path)")
                } else {
                    logger.error("fail to extract Sony ARW thumbnail from file")
                }
            } else {
                logger.error("unsupported file format: \(fileExtension). Only HEIC, HEIF, JPG, JPEG, and ARW are supported.")
            }

        } catch {
            logger.error("\(error.localizedDescription)")
        }
    }
}
