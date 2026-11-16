import Foundation
import FoundationModels
import NaturalLanguage

// wroopmark-ai: the on-device models, in a process of their own.
//
// The core starts it when it needs vectors (meaning search) or a summary,
// and talks JSON lines over stdin/stdout:
//
//   {"op":"embed","texts":["…","…"]}         → {"model":"…","vecs":["<base64 f32le>"|null,…]}
//   {"op":"summarize","text":"…","tags":[…]} → {"summary":"…","tags":["…"]}
//   {"op":"expand","query":"…"}              → {"terms":["…",…]}   (related search words)
//   {"op":"status"}                          → {"embed":true,"embed_model":"…","llm":"available"|"<reason>"}
//
// It quits on its own after a minute without requests (or when stdin
// closes), so the model memory goes back to the system right away and the
// app itself never holds it.

let idleTimeout: TimeInterval = 60

final class Activity: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    private var busy = false

    func begin() { lock.withLock { busy = true; last = Date() } }
    func end() { lock.withLock { busy = false; last = Date() } }
    var idle: Bool { lock.withLock { !busy && Date().timeIntervalSince(last) > idleTimeout } }
}

let activity = Activity()

// MARK: - Embeddings

/// NaturalLanguage's contextual embedding for Latin-script text (Turkish,
/// English and most European languages share one model), mean-pooled
/// over tokens into one sentence vector.
enum Embedder {
    nonisolated(unsafe) static var model: NLContextualEmbedding?
    nonisolated(unsafe) static var loadError: String?

    static func load() -> NLContextualEmbedding? {
        if let model { return model }
        if loadError != nil { return nil }
        guard let m = NLContextualEmbedding(script: .latin) else {
            loadError = Summarizer.english ? "this Mac has no embedding model" : "bu Mac'te gömme modeli yok"
            return nil
        }
        if !m.hasAvailableAssets {
            // A one-time download by the system (tens of MB).
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var ok = false
            m.requestAssets { result, _ in
                ok = result == .available
                done.signal()
            }
            if done.wait(timeout: .now() + 600) == .timedOut || !ok {
                loadError = Summarizer.english ? "the embedding model could not be downloaded" : "gömme modeli indirilemedi"
                return nil
            }
        }
        do {
            try m.load()
        } catch {
            loadError = (Summarizer.english ? "the embedding model could not be loaded: " : "gömme modeli yüklenemedi: ") + error.localizedDescription
            return nil
        }
        model = m
        return m
    }

    static var identifier: String {
        guard let m = model ?? load() else { return "" }
        return "\(m.modelIdentifier)#\(m.revision)/\(m.dimension)"
    }

    static func vector(_ text: String) -> [Float]? {
        guard let m = load() else { return nil }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
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

    static func base64(_ v: [Float]) -> String {
        var copy = v
        return Data(bytes: &copy, count: copy.count * MemoryLayout<Float>.size).base64EncodedString()
    }
}

// MARK: - Summaries

enum Summarizer {
    static var availability: String {
        switch SystemLanguageModel.default.availability {
        case .available: "available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: english ? "This Mac does not support Apple Intelligence" : "Bu Mac Apple Intelligence desteklemiyor"
            case .appleIntelligenceNotEnabled: english ? "Apple Intelligence is off (System Settings → Apple Intelligence & Siri)" : "Apple Intelligence kapalı (Sistem Ayarları → Apple Intelligence ve Siri)"
            case .modelNotReady: english ? "The model is not ready yet (it may be downloading)" : "Model henüz hazır değil (indiriliyor olabilir)"
            @unknown default: english ? "The model is unavailable" : "Model kullanılamıyor"
            }
        }
    }

    static let englishInstructions = """
    You help with an archive of saved posts. You will get one saved post or page.
    Write only these two lines and nothing else:
    SUMMARY: <the content in English, in at most two short sentences>
    TAGS: <1-4 short lowercase tags, separated by commas>
    Tags name the topic (e.g. ai, rust, recipe). Prefer the existing tags given, when they fit.
    """

    static let englishExpandInstructions = """
    Someone searches a personal archive. Write keywords that related items may contain:
    synonyms, close terms, English and Turkish equivalents, abbreviations. 6 to 12 of them, 1-2 words each.
    Write only the comma-separated list, no explanation.
    """

    /// Summaries and search words in the user's language: Turkish for
    /// Turkish, English for everyone else.
    static var english: Bool { !(Locale.preferredLanguages.first ?? "tr").hasPrefix("tr") }

    static let instructions = """
    Sen bir kayıt arşivinin yardımcısısın. Sana kaydedilmiş bir gönderi ya da sayfa verilecek.
    Yalnızca şu iki satırı yaz, başka hiçbir şey yazma:
    ÖZET: <içeriği Türkçe, en fazla iki kısa cümleyle anlatan özet>
    ETİKETLER: <virgülle ayrılmış 1-4 kısa, küçük harfli etiket>
    Etiketler konuyu anlatsın (ör. yapay zeka, rust, yemek tarifi). Mümkünse verilen mevcut etiketlerden seç.
    """

    static func run(text: String, tags: [String]) async throws -> (String, [String]) {
        let session = LanguageModelSession(instructions: english ? englishInstructions : instructions)
        var prompt = (english ? "Content:" : "İçerik:") + "\n\(text)\n"
        if !tags.isEmpty {
            prompt += (english ? "\nExisting tags: " : "\nMevcut etiketler: ") + tags.prefix(80).joined(separator: ", ") + "\n"
        }
        let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 220))
        return parse(response.content)
    }

    /// "ÖZET:", "Özet:", "ozet:" alike (Turkish İ/ı and accents folded).
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
        let session = LanguageModelSession(instructions: english ? englishExpandInstructions : expandInstructions)
        let response = try await session.respond(to: (english ? "Search: " : "Arama: ") + query, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 120))
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
            if k.hasPrefix("ozet:") || k.hasPrefix("summary:") {
                summary = value
            } else if k.hasPrefix("etiketler:") || k.hasPrefix("etiket:") || k.hasPrefix("tags:") || k.hasPrefix("tag:") {
                tags = value.split(separator: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " #.\"'")).lowercased(with: Locale(identifier: "tr")) }
                    .filter { !$0.isEmpty }
            } else if summary.isEmpty && !line.isEmpty && !k.hasPrefix("etiket") && !k.hasPrefix("tag") {
                summary = line
            }
        }
        return (summary, tags)
    }
}

// MARK: - Loop

func reply(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          let line = String(data: data, encoding: .utf8) else { return }
    FileHandle.standardOutput.write((line + "\n").data(using: .utf8) ?? Data())
}

func handle(_ req: [String: Any]) {
    switch req["op"] as? String {
    case "embed":
        let texts = req["texts"] as? [String] ?? []
        var vecs: [Any] = []
        for t in texts {
            vecs.append(Embedder.vector(t).map(Embedder.base64) ?? NSNull())
        }
        if Embedder.model == nil, let e = Embedder.loadError {
            reply(["error": e])
        } else {
            reply(["model": Embedder.identifier, "vecs": vecs])
        }
    case "summarize":
        let text = req["text"] as? String ?? ""
        let tags = req["tags"] as? [String] ?? []
        guard Summarizer.availability == "available" else {
            reply(["error": Summarizer.availability])
            return
        }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: [String: Any] = [:]
        Task.detached {
            do {
                let (s, t) = try await Summarizer.run(text: text, tags: tags)
                out = ["summary": s, "tags": t]
            } catch {
                out = ["error": "özetlenemedi: \(error.localizedDescription)"]
            }
            done.signal()
        }
        done.wait()
        reply(out)
    case "expand":
        let query = req["query"] as? String ?? ""
        guard Summarizer.availability == "available" else {
            reply(["error": Summarizer.availability])
            return
        }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: [String: Any] = [:]
        Task.detached {
            do {
                out = ["terms": try await Summarizer.expand(query)]
            } catch {
                out = ["error": "genişletilemedi: \(error.localizedDescription)"]
            }
            done.signal()
        }
        done.wait()
        reply(out)
    case "status":
        let m = Embedder.load()
        var status: [String: Any] = ["embed": m != nil, "llm": Summarizer.availability]
        if m != nil { status["embed_model"] = Embedder.identifier }
        if let e = Embedder.loadError { status["embed_error"] = e }
        reply(status)
    default:
        reply(["error": "bilinmeyen işlem"])
    }
}

Thread.detachNewThread {
    while true {
        Thread.sleep(forTimeInterval: 5)
        if activity.idle { exit(0) }
    }
}

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
          let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        reply(["error": "geçersiz istek"])
        continue
    }
    activity.begin()
    handle(req)
    activity.end()
}
