import CWroopmark
import Foundation
import FoundationModels
import NaturalLanguage

/// In-process on-device models for iOS (the sandbox cannot start
/// `wroopmark-ai`), plugged into the Rust core through `wm_set_ai`.
/// Follows the same JSON protocol as `apple/AI/main.swift`.
enum PhoneAI {
    private final class ReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var dict: [String: Any] = [:]

        func set(_ value: [String: Any]) {
            lock.withLock { dict = value }
        }

        func get() -> [String: Any] {
            lock.withLock { dict }
        }
    }

    private enum Embedder {
        private static let lock = NSLock()
        nonisolated(unsafe) static var model: NLContextualEmbedding?
        nonisolated(unsafe) static var loadError: String?
        /// When loading last failed: tried again after ten minutes (the
        /// download may have needed Wi-Fi or space that is there now).
        nonisolated(unsafe) static var failedAt: Date?

        static func load() -> NLContextualEmbedding? {
            lock.withLock { loadLocked() }
        }

        private static func loadLocked() -> NLContextualEmbedding? {
            if let model { return model }
            if loadError != nil, let failedAt, Date.now.timeIntervalSince(failedAt) < 600 { return nil }
            loadError = nil
            failedAt = nil
            guard let m = NLContextualEmbedding(script: .latin) else {
                fail("Bu iPhone'da gömme modeli yok")
                return nil
            }
            if !m.hasAvailableAssets {
                let box = ReplyBox()
                let done = DispatchSemaphore(value: 0)
                m.requestAssets { result, _ in
                    box.set(["ok": result == .available])
                    done.signal()
                }
                if done.wait(timeout: .now() + 120) == .timedOut || (box.get()["ok"] as? Bool) != true {
                    fail("gömme modeli indirilemedi")
                    return nil
                }
            }
            do {
                try m.load()
            } catch {
                fail("gömme modeli yüklenemedi: \(error.localizedDescription)")
                return nil
            }
            model = m
            return m
        }

        private static func fail(_ message: String) {
            loadError = message
            failedAt = .now
        }

        static func unload() {
            lock.withLock {
                model?.unload()
                model = nil
            }
        }

        static var lastError: String? {
            lock.withLock { loadError }
        }

        static var identifier: String {
            lock.withLock {
                guard let m = loadLocked() else { return "" }
                return "\(m.modelIdentifier)#\(m.revision)/\(m.dimension)"
            }
        }

        static func vector(_ text: String) -> [Float]? {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return nil }
            return lock.withLock {
                guard let m = loadLocked() else { return nil }
                return autoreleasepool {
                    guard let result = try? m.embeddingResult(for: clean, language: nil) else { return nil }
                    var sum = [Double](repeating: 0, count: m.dimension)
                    var count = 0
                    result.enumerateTokenVectors(in: clean.startIndex..<clean.endIndex) { vec, _ in
                        if vec.count == sum.count {
                            for i in 0..<vec.count { sum[i] += vec[i] }
                            count += 1
                        }
                        return true
                    }
                    guard count > 0 else { return nil }
                    return sum.map { Float($0 / Double(count)) }
                }
            }
        }

        static func base64(_ v: [Float]) -> String {
            var copy = v
            return Data(bytes: &copy, count: copy.count * MemoryLayout<Float>.size).base64EncodedString()
        }
    }

    private enum Summarizer {
        static var availability: String {
            switch SystemLanguageModel.default.availability {
            case .available: "available"
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: "Bu cihaz Apple Intelligence desteklemiyor"
                case .appleIntelligenceNotEnabled: "Apple Intelligence kapalı (Ayarlar → Apple Intelligence ve Siri)"
                case .modelNotReady: "Model henüz hazır değil (indiriliyor olabilir)"
                @unknown default: "Model kullanılamıyor"
                }
            }
        }

        static let instructions = """
        Sen bir kayıt arşivinin yardımcısısın. Sana kaydedilmiş bir gönderi ya da sayfa verilecek.
        Yalnızca şu iki satırı yaz, başka hiçbir şey yazma:
        ÖZET: <içeriği Türkçe, en fazla iki kısa cümleyle anlatan özet>
        ETİKETLER: <virgülle ayrılmış 1-4 kısa, küçük harfli etiket>
        Etiketler konuyu anlatsın (ör. yapay zeka, rust, yemek tarifi). Mümkünse verilen mevcut etiketlerden seç.
        """

        static func run(text: String, tags: [String]) async throws -> (String, [String]) {
            let session = LanguageModelSession(instructions: instructions)
            var prompt = "İçerik:\n\(text)\n"
            if !tags.isEmpty {
                prompt += "\nMevcut etiketler: \(tags.prefix(80).joined(separator: ", "))\n"
            }
            let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 220))
            return parse(response.content)
        }

        static func key(_ line: String) -> String {
            line.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .replacingOccurrences(of: "ı", with: "i")
                .replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: .whitespaces)
        }

        static let expandInstructions = """
        Bir kişisel arşivde arama yapılıyor. Verilen aramayla ilgili kayıtlarda geçebilecek anahtar kelimeleri yaz:
        eş anlamlılar, yakın terimler, İngilizce ve Türkçe karşılıkları, kısaltmalar. 6 ile 12 arası, her biri 1-2 kelime.
        Yalnızca virgülle ayrılmış listeyi yaz, açıklama yazma.
        """

        static func expand(_ query: String) async throws -> [String] {
            let session = LanguageModelSession(instructions: expandInstructions)
            let response = try await session.respond(to: "Arama: \(query)", options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 120))
            let text = response.content.replacingOccurrences(of: "\n", with: ",")
            return text.split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -•*#.\"'0123456789)")).lowercased(with: Locale(identifier: "tr")) }
                .filter { !$0.isEmpty && $0.count <= 40 }
        }

        static func parse(_ out: String) -> (String, [String]) {
            var summary = ""
            var tags: [String] = []
            for raw in out.split(whereSeparator: \.isNewline) {
                let line = raw.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
                let k = key(line)
                let value = String(line.drop { $0 != ":" }.dropFirst()).trimmingCharacters(in: .whitespaces)
                if k.hasPrefix("ozet:") {
                    summary = value
                } else if k.hasPrefix("etiketler:") || k.hasPrefix("etiket:") {
                    tags = value.split(separator: ",")
                        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " #.\"'")).lowercased(with: Locale(identifier: "tr")) }
                        .filter { !$0.isEmpty }
                } else if summary.isEmpty && !line.isEmpty && !k.hasPrefix("etiket") {
                    summary = line
                }
            }
            return (summary, tags)
        }
    }

    private static let registered = NSLock()
    nonisolated(unsafe) private static var didRegister = false

    static func register() {
        registered.lock()
        let first = !didRegister
        didRegister = true
        registered.unlock()
        guard first else { return }
        wm_set_ai { reqPtr, ctx, out in
            guard let reqPtr,
                  let data = String(cString: reqPtr).data(using: .utf8),
                  let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                PhoneAI.reply(["error": "geçersiz istek"], ctx: ctx, out: out)
                return
            }
            PhoneAI.reply(PhoneAI.handle(req), ctx: ctx, out: out)
        }
    }

    static func unload() {
        Embedder.unload()
    }

    private static func reply(_ obj: [String: Any], ctx: UnsafeMutableRawPointer?, out: WmAiOut?) {
        guard let out,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8)
        else { return }
        str.withCString { out(ctx, $0) }
    }

    private static func handle(_ req: [String: Any]) -> [String: Any] {
        switch req["op"] as? String {
        case "embed":
            let texts = req["texts"] as? [String] ?? []
            var vecs: [Any] = []
            for t in texts {
                vecs.append(Embedder.vector(t).map(Embedder.base64) ?? NSNull())
            }
            let id = Embedder.identifier
            if id.isEmpty, let e = Embedder.lastError {
                return ["error": e]
            }
            return ["model": id, "vecs": vecs]
        case "summarize":
            let text = req["text"] as? String ?? ""
            let tags = req["tags"] as? [String] ?? []
            guard Summarizer.availability == "available" else {
                return ["error": Summarizer.availability]
            }
            let box = ReplyBox()
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let (s, t) = try await Summarizer.run(text: text, tags: tags)
                    box.set(["summary": s, "tags": t])
                } catch {
                    box.set(["error": "özetlenemedi: \(error.localizedDescription)"])
                }
                done.signal()
            }
            // A stuck model must not hold the core's AI lock for ever.
            if done.wait(timeout: .now() + 90) == .timedOut { return ["error": "model yanıt vermedi"] }
            return box.get()
        case "expand":
            let query = req["query"] as? String ?? ""
            guard Summarizer.availability == "available" else {
                return ["error": Summarizer.availability]
            }
            let box = ReplyBox()
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    box.set(["terms": try await Summarizer.expand(query)])
                } catch {
                    box.set(["error": "genişletilemedi: \(error.localizedDescription)"])
                }
                done.signal()
            }
            // A stuck model must not hold the core's AI lock for ever.
            if done.wait(timeout: .now() + 90) == .timedOut { return ["error": "model yanıt vermedi"] }
            return box.get()
        case "status":
            let m = Embedder.load()
            var status: [String: Any] = ["embed": m != nil, "llm": Summarizer.availability]
            if m != nil { status["embed_model"] = Embedder.identifier }
            if let e = Embedder.lastError { status["embed_error"] = e }
            return status
        default:
            return ["error": "bilinmeyen işlem"]
        }
    }
}
