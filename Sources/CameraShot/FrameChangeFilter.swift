import CoreGraphics
import Foundation

/// Lightweight image-difference gate used to skip near-identical screenshots.
///
/// The image is downsampled and converted to luma; we then measure the fraction
/// of sampled pixels whose luma changed by at least `pixelDeltaThreshold`.
final class FrameChangeFilter {
    private let minimumChangedRatio: Double
    private let pixelDeltaThreshold: UInt8
    private let sampleWidth: Int
    private let sampleHeight: Int

    private var previousAcceptedSignature: [UInt8]?

    init(
        minimumChangedRatio: Double = 0.03,
        pixelDeltaThreshold: UInt8 = 18,
        sampleWidth: Int = 160,
        sampleHeight: Int = 90
    ) {
        self.minimumChangedRatio = minimumChangedRatio
        self.pixelDeltaThreshold = pixelDeltaThreshold
        self.sampleWidth = sampleWidth
        self.sampleHeight = sampleHeight
    }

    /// Returns true when this frame should be accepted/saved.
    func shouldAccept(_ image: CGImage) -> Bool {
        guard let current = signature(for: image) else { return true }
        guard let previous = previousAcceptedSignature else {
            previousAcceptedSignature = current
            return true
        }

        let changedRatio = differenceRatio(current: current, previous: previous)
        let accepted = changedRatio >= minimumChangedRatio
        if accepted {
            previousAcceptedSignature = current
        }
        return accepted
    }

    private func signature(for image: CGImage) -> [UInt8]? {
        var rgba = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        guard let ctx = CGContext(
            data: &rgba,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: sampleWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        var luma = [UInt8](repeating: 0, count: sampleWidth * sampleHeight)
        for i in 0..<luma.count {
            let idx = i * 4
            let r = Int(rgba[idx])
            let g = Int(rgba[idx + 1])
            let b = Int(rgba[idx + 2])
            // Integer approximation of ITU-R BT.601 luma.
            luma[i] = UInt8((77 * r + 150 * g + 29 * b) >> 8)
        }
        return luma
    }

    private func differenceRatio(current: [UInt8], previous: [UInt8]) -> Double {
        guard current.count == previous.count, !current.isEmpty else { return 1.0 }

        let threshold = Int(pixelDeltaThreshold)
        var changed = 0
        for i in 0..<current.count {
            if abs(Int(current[i]) - Int(previous[i])) >= threshold {
                changed += 1
            }
        }
        return Double(changed) / Double(current.count)
    }
}
