# ImageThumbnailer

A fast and efficient Swift library for extracting thumbnails from various image formats including HEIF, JPEG, and Sony ARW files.

## Installation

### Swift Package Manager

Add this to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/wangrunji0408/image-thumbnailer", from: "1.0.0")
]
```

## Usage

### Library Usage

```swift
import ImageThumbnailer

// Create a read function for your image file
let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
    // Your file reading implementation
    return fileData.subdata(in: Int(offset)..<Int(offset + length))
}

// Extract thumbnail with minimum 200px short side
// For HEIF/HEIC files
if let thumbnail = try await readHeifThumbnail(readAt: readAt, minShortSide: 200) {
    print("Extracted thumbnail: \(thumbnail.width)x\(thumbnail.height)")
    // Use thumbnail.data for the image data
}

// For JPEG files
if let thumbnail = try await readJpegThumbnail(readAt: readAt, minShortSide: 200) {
    print("Extracted JPEG thumbnail: \(thumbnail.width)x\(thumbnail.height)")
}

// For Sony ARW files
if let thumbnail = try await readSonyArwThumbnail(readAt: readAt, minShortSide: 200) {
    print("Extracted Sony ARW thumbnail: \(thumbnail.width)x\(thumbnail.height)")
}

// Or get as platform image (UIImage/NSImage)
if let image = try await readHeifThumbnailAsImage(readAt: readAt, minShortSide: 200) {
    // Use the image directly
}
```

### Command Line Usage

```bash
# Extract thumbnail from various image formats
swift run ImageThumbnailerCLI input.heic
swift run ImageThumbnailerCLI input.jpg
swift run ImageThumbnailerCLI input.arw

# Extract with minimum 300px short side
swift run ImageThumbnailerCLI input.heic -s 300
```

## Supported Formats

- HEIF/HEIC files
- JPEG files
- Sony ARW files
- More formats coming soon

## Requirements

- Swift 5.9+
- macOS 11.0+ / iOS 12.0+

## License

MIT License
