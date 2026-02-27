import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageCodecError: Error {
    case invalidImageData
    case couldNotCreateContext
    case couldNotEncodeImage
}

enum ImageCodec {
    static func downsample(
        data: Data,
        targetSize: CGSize,
        displayScale: CGFloat
    ) throws -> ImagePagerImage {
        let targetPixelSize = CGSize(
            width: max(targetSize.width * max(displayScale, 1), 1),
            height: max(targetSize.height * max(displayScale, 1), 1)
        )

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageCodecError.invalidImageData
        }

        let maxPixelSize = Int(max(targetPixelSize.width, targetPixelSize.height).rounded(.up))
        let options: CFDictionary = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1),
        ] as CFDictionary

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw ImageCodecError.invalidImageData
        }

        let fitted = try fit(image: thumbnail, within: targetPixelSize)

        return ImagePagerImage(
            cgImage: fitted,
            pixelSize: CGSize(width: fitted.width, height: fitted.height),
            scale: max(displayScale, 1)
        )
    }

    static func preferredUTType(for data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        return CGImageSourceGetType(source) as String?
    }

    static func encode(image: CGImage, preferredUTType: String?) throws -> Data {
        let targetUTType = preferredUTType ?? UTType.png.identifier
        let encoded = NSMutableData()

        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            targetUTType as CFString,
            1,
            nil
        ) else {
            throw ImageCodecError.couldNotEncodeImage
        }

        let properties: CFDictionary
        if targetUTType == UTType.jpeg.identifier {
            properties = [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        } else {
            properties = [:] as CFDictionary
        }

        CGImageDestinationAddImage(destination, image, properties)

        guard CGImageDestinationFinalize(destination) else {
            throw ImageCodecError.couldNotEncodeImage
        }

        return encoded as Data
    }

    private static func fit(image: CGImage, within bounds: CGSize) throws -> CGImage {
        let maxWidth = max(Int(bounds.width.rounded(.up)), 1)
        let maxHeight = max(Int(bounds.height.rounded(.up)), 1)
        let widthScale = CGFloat(maxWidth) / CGFloat(image.width)
        let heightScale = CGFloat(maxHeight) / CGFloat(image.height)
        let scale = min(widthScale, heightScale, 1)
        let outputWidth = max(Int((CGFloat(image.width) * scale).rounded(.toNearestOrAwayFromZero)), 1)
        let outputHeight = max(Int((CGFloat(image.height) * scale).rounded(.toNearestOrAwayFromZero)), 1)

        guard outputWidth != image.width || outputHeight != image.height else {
            return image
        }

        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageCodecError.couldNotCreateContext
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))

        guard let output = context.makeImage() else {
            throw ImageCodecError.couldNotCreateContext
        }

        return output
    }
}
