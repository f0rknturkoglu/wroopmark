import Foundation
import ImageIO
import Vision

// wroopmark-ocr: reads text in images with Vision and exits.
//
// The app runs it once per batch: file paths on stdin (one per line), one
// JSON string per line on stdout, in the same order. Vision keeps gigabytes
// of model buffers alive for the life of the process; in a helper that
// memory is returned to the system the moment the batch is done.

/// On-device text recognition with Vision: no network, no model to ship.
enum OCR {
    /// Below this the line is usually noise (textures, faces, logos).
    private static let minConfidence: Float = 0.45
    /// Screenshots of long threads can be huge; this is plenty for search.
    private static let maxChars = 6000

    /// Recognized lines of one image, top to bottom, or "" when none.
    static func text(at url: URL) -> String {
        // Vision and ImageIO hand back autoreleased buffers; on a background
        // thread nothing drains them unless each image gets its own pool
        // (without it a library pass held ~3 GB until quit).
        autoreleasepool { recognize(url) }
    }

    private static func recognize(_ url: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = downsampled(src) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["tr-TR", "en-US"]
        // The languages are given; automatic detection adds a model run
        // and is where the recognizer was seen deadlocking.
        request.automaticallyDetectsLanguage = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return "" }
        let lines = (request.results ?? []).compactMap { obs -> String? in
            guard let best = obs.topCandidates(1).first, best.confidence >= minConfidence else { return nil }
            let line = best.string.trimmingCharacters(in: .whitespaces)
            return line.count >= 2 ? line : nil
        }
        return String(lines.joined(separator: "\n").prefix(maxChars))
    }

    /// Vision does not need more than ~2K pixels to read text, and decoding
    /// less keeps memory and time down on 4K photos.
    private static func downsampled(_ src: CGImageSource) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2200,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

while let line = readLine() {
    let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let text = path.isEmpty ? "" : OCR.text(at: URL(fileURLWithPath: path))
    let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed])) ?? Data("\"\"".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
