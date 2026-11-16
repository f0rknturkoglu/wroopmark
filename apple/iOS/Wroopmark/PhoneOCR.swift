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

    struct Inspection: Sendable {
        let text: String
        let labels: String
        let imghash: Int64?
    }

    static func inspect(at url: URL) -> Inspection {
        autoreleasepool { analyze(url) }
    }

    private static func recognize(_ url: URL) -> String {
        analyze(url).text
    }

    private static func analyze(_ url: URL) -> Inspection {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = downsampled(src) else {
            return Inspection(text: "", labels: "", imghash: nil)
        }
        let textReq = VNRecognizeTextRequest()
        textReq.recognitionLevel = .accurate
        textReq.usesLanguageCorrection = true
        textReq.recognitionLanguages = ["tr-TR", "en-US"]
        textReq.automaticallyDetectsLanguage = false

        let classifyReq = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        _ = try? handler.perform([textReq, classifyReq])

        let lines = (textReq.results ?? []).compactMap { obs -> String? in
            guard let best = obs.topCandidates(1).first, best.confidence >= minConfidence else { return nil }
            let line = best.string.trimmingCharacters(in: .whitespaces)
            return line.count >= 2 ? line : nil
        }
        let text = String(lines.joined(separator: "\n").prefix(maxChars))
        let labels = Self.bilingualLabels(from: classifyReq.results ?? [])
        let imghash = Self.dHash(image)
        return Inspection(text: text, labels: labels, imghash: imghash)
    }

    private static let labelMapTR: [String: String] = [
        "cat": "kedi", "feline": "kedi", "dog": "köpek", "canine": "köpek",
        "bird": "kuş", "fish": "balık", "animal": "hayvan", "horse": "at",
        "insect": "böcek", "person": "insan kişi", "people": "insanlar",
        "portrait": "portre", "face": "yüz", "crowd": "kalabalık",
        "hand": "el", "child": "çocuk", "baby": "bebek",
        "food": "yemek", "dish": "yemek tabak", "meal": "yemek",
        "dessert": "tatlı", "cake": "pasta tatlı", "coffee": "kahve",
        "tea": "çay", "drink": "içecek", "beverage": "içecek",
        "fruit": "meyve", "vegetable": "sebze", "bread": "ekmek",
        "pizza": "pizza", "burger": "burger", "salad": "salata",
        "screen": "ekran", "screenshot": "ekran görüntüsü", "display": "ekran",
        "monitor": "monitör ekran", "computer": "bilgisayar", "laptop": "dizüstü bilgisayar",
        "keyboard": "klavye", "phone": "telefon", "mobile_phone": "telefon",
        "smartphone": "telefon", "cell_phone": "telefon",
        "document": "belge", "paper": "kağıt belge", "receipt": "fiş fatura",
        "book": "kitap", "diagram": "diyagram şema", "chart": "grafik tablo",
        "graph": "grafik", "plot": "grafik", "map": "harita",
        "logo": "logo marka", "sign": "tabela işaret", "signage": "tabela",
        "car": "araba otomobil", "automobile": "araba otomobil", "vehicle": "araç",
        "motorcycle": "motosiklet", "bicycle": "bisiklet", "bike": "bisiklet",
        "train": "tren", "airplane": "uçak", "aircraft": "uçak",
        "boat": "tekne", "ship": "gemi",
        "building": "bina yapı", "architecture": "mimari yapı", "house": "ev",
        "home": "ev", "bridge": "köprü", "city": "şehir", "street": "sokak",
        "road": "yol", "room": "oda", "interior": "iç mekan", "outdoor": "dış mekan",
        "furniture": "mobilya", "desk": "masa", "table": "masa", "chair": "sandalye",
        "mountain": "dağ", "sea": "deniz", "ocean": "okyanus deniz",
        "beach": "plaj sahil", "water": "su", "sky": "gökyüzü",
        "cloud": "bulut", "sunset": "gün batımı", "sunrise": "gün doğumu",
        "night": "gece", "forest": "orman", "tree": "ağaç", "flower": "çiçek",
        "plant": "bitki", "snow": "kar", "ice": "buz",
        "art": "sanat", "painting": "tablo resim", "drawing": "çizim",
        "illustration": "çizim illüstrasyon", "cartoon": "çizgi animasyon",
        "music": "müzik", "guitar": "gitar müzik", "piano": "piyano müzik",
        "sport": "spor", "fashion": "moda giyim", "clothing": "giyim kıyafet",
        "shoe": "ayakkabı", "watch": "saat", "clock": "saat",
        "money": "para finans", "fire": "ateş", "toy": "oyuncak", "game": "oyun",
    ]

    private static func bilingualLabels(from observations: [VNClassificationObservation]) -> String {
        let top = observations
            .filter { $0.confidence >= 0.35 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(6)
        var seen: Set<String> = []
        var tokens: [String] = []
        for obs in top {
            let key = obs.identifier.lowercased()
            let enWords = key.replacingOccurrences(of: "_", with: " ").split(separator: " ").map(String.init)
            let trWords = (labelMapTR[key] ?? "").split(separator: " ").map(String.init)
            for w in trWords + enWords where !w.isEmpty && seen.insert(w).inserted {
                tokens.append(w)
            }
        }
        return tokens.joined(separator: " ")
    }

    private static func dHash(_ image: CGImage) -> Int64? {
        let w = 9
        let h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        let space = CGColorSpaceCreateDeviceGray()
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ptr = buf.baseAddress,
                  let ctx = CGContext(
                      data: ptr,
                      width: w,
                      height: h,
                      bitsPerComponent: 8,
                      bytesPerRow: w,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var bits: UInt64 = 0
        var shift = 0
        for row in 0..<h {
            let base = row * w
            for col in 0..<(w - 1) {
                if pixels[base + col] > pixels[base + col + 1] {
                    bits |= (UInt64(1) << shift)
                }
                shift += 1
            }
        }
        guard bits != 0, bits != UInt64.max else { return nil }
        return Int64(bitPattern: bits)
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
                    let inspections = await Task.detached(priority: .utility) {
                        files.map { PhoneOCR.inspect(at: URL(fileURLWithPath: $0)) }
                    }.value
                    let text = inspections.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
                    var seenLabels: Set<String> = []
                    let mergedLabels = inspections.flatMap { $0.labels.split(separator: " ").map(String.init) }
                        .filter { seenLabels.insert($0).inserted }
                        .joined(separator: " ")
                    let hash = inspections.compactMap(\.imghash).first
                    if (try? await self.core.run(.setOCR(
                        id: item.id,
                        text: text,
                        labels: mergedLabels.isEmpty ? nil : mergedLabels,
                        imghash: hash
                    ))) != nil { read += 1 }
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
