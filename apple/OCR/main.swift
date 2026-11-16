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

    struct Inspection: Encodable {
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
        // The languages are given; automatic detection adds a model run
        // and is where the recognizer was seen deadlocking.
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

let encoder = JSONEncoder()
while let line = readLine() {
    let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let result = path.isEmpty
        ? OCR.Inspection(text: "", labels: "", imghash: nil)
        : OCR.inspect(at: URL(fileURLWithPath: path))
    let data = (try? encoder.encode(result)) ?? Data("{\"text\":\"\",\"labels\":\"\",\"imghash\":null}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
