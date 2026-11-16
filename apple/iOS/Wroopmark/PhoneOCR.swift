import Foundation
import ImageIO
import Vision

/// Reads the text in saved pictures on the iPhone (the Mac does it in its
/// `wroopmark-ocr` helper; an iOS app cannot start one). Same settings as
/// the helper, so both devices find the same words.
enum PhoneOCR {
    private static let minConfidence: Float = 0.45
    private static let maxChars = 6000

    /// Recognized lines of one picture, top to bottom, or "" when none.
    static func text(at url: URL) -> String {
        // Each picture gets its own pool: Vision's buffers are autoreleased
        // and nothing drains them on a background thread otherwise.
        autoreleasepool { recognize(url) }
    }

    private static func recognize(_ url: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = downsampled(src) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["tr-TR", "en-US"]
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

    /// ~2K pixels is enough to read text, and much lighter than a 4K photo.
    private static func downsampled(_ src: CGImageSource) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2200,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

extension PhoneModel {
    /// Works through the pictures nobody has read yet, a few posts at a
    /// time, while the app is open and Low Power Mode is off. Posts from
    /// the Mac arrive with their text already read.
    func startOCR() {
        guard ocrTask == nil, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        struct Pending: Decodable, Sendable { let id: String; let files: [String] }
        ocrTask = Task(priority: .utility) { [weak self] in
            defer { self?.ocrTask = nil }
            while let self, !Task.isCancelled, !ProcessInfo.processInfo.isLowPowerModeEnabled {
                guard let batch: [Pending] = try? await self.core.call(.ocrPending(limit: 8)), !batch.isEmpty else { break }
                var read = 0
                for item in batch {
                    guard !Task.isCancelled else { return }
                    let files = item.files
                    let text = await Task.detached(priority: .utility) {
                        files.map { PhoneOCR.text(at: URL(fileURLWithPath: $0)) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                    }.value
                    if (try? await self.core.run(.setOCR(id: item.id, text: text))) != nil { read += 1 }
                }
                // Nothing could be written: stop rather than loop on the same posts.
                if read == 0 { break }
            }
        }
    }

    func stopOCR() {
        ocrTask?.cancel()
        ocrTask = nil
    }
}
