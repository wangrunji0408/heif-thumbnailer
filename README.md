# HeifThumbnailer

A fast and efficient Swift library for extracting thumbnails from HEIF images.

## Installation

### Swift Package Manager

Add this to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/wangrunji0408/heif-thumbnailer", from: "1.0.0")
]
```

## Usage

### Library Usage

```swift
import HeifThumbnailer

// Create a read function for your HEIC file
let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
    // Your file reading implementation
    return fileData.subdata(in: Int(offset)..<Int(offset + length))
}

// Extract thumbnail with minimum 200px short side
if let thumbnail = try await readHeifThumbnail(readAt: readAt, minShortSide: 200) {
    print("Extracted thumbnail: \(thumbnail.width)x\(thumbnail.height)")
    // Use thumbnail.data for the image data
}

// Or get as platform image (UIImage/NSImage)
if let image = try await readHeifThumbnailAsImage(readAt: readAt, minShortSide: 200) {
    // Use the image directly
}
```

### Command Line Usage

```bash
# Extract thumbnail from HEIC file
swift run HeifThumbnailerCLI input.heic

# Extract with minimum 300px short side
swift run HeifThumbnailerCLI input.heic -s 300
```

## Requirements

- Swift 5.9+
- macOS 11.0+ / iOS 12.0+

## License

MIT License
