import AppKit
import ImageIO

class ScreenCaptureManager {
    /// Maximum pixel dimension (width or height) for the saved screenshot.
    /// Claude API rejects images above ~5 MB; 1500px JPEG stays well under that.
    private static let maxDimension: CGFloat = 1500

    static func captureScreen() -> URL? {
        let fileManager = FileManager.default
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            log("ScreenCaptureManager: Could not find documents directory")
            return nil
        }
        let screenshotsDirectory = documentsDirectory
            .appendingPathComponent("Omi")
            .appendingPathComponent("Screenshots")

        do {
            try fileManager.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            log("ScreenCaptureManager: Error creating directory: \(error)")
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let fileName = "screenshot-\(timestamp).jpg"
        let fileURL = screenshotsDirectory.appendingPathComponent(fileName)

        guard let rawImage = CGDisplayCreateImage(CGMainDisplayID()) else {
            log("ScreenCaptureManager: Could not capture screen")
            return nil
        }

        // Resize if needed so the image fits within maxDimension on the longest side.
        let srcW = CGFloat(rawImage.width)
        let srcH = CGFloat(rawImage.height)
        let scale = min(1.0, maxDimension / max(srcW, srcH))
        let dstW = Int(srcW * scale)
        let dstH = Int(srcH * scale)

        let image: CGImage
        if scale < 1.0 {
            let colorSpace = rawImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            if let ctx = CGContext(
                data: nil,
                width: dstW,
                height: dstH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) {
                ctx.interpolationQuality = .high
                ctx.draw(rawImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
                image = ctx.makeImage() ?? rawImage
            } else {
                image = rawImage
            }
        } else {
            image = rawImage
        }

        guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, "public.jpeg" as CFString, 1, nil) else {
            log("ScreenCaptureManager: Could not create image destination")
            return nil
        }

        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.75]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)

        if !CGImageDestinationFinalize(destination) {
            log("ScreenCaptureManager: Could not save image")
            return nil
        }

        log("ScreenCaptureManager: Screenshot saved to \(fileURL.path) (\(dstW)×\(dstH), scale=\(String(format: "%.2f", scale)))")
        return fileURL
    }
}
