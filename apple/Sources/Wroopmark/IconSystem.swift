import AppKit
import SwiftUI

// MARK: - Link Category

enum LinkCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case github
    case drive
    case mega
    case youtube
    case arxiv
    case twitter
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .github: "GitHub"
        case .drive: "Google Drive"
        case .mega: "Mega.nz"
        case .youtube: "YouTube"
        case .arxiv: "arXiv"
        case .twitter: "Twitter / X"
        case .other: "Diğer"
        }
    }

    var symbolFallback: String {
        switch self {
        case .github: "chevron.left.forwardslash.chevron.right"
        case .drive: "externaldrive.fill.badge.icloud"
        case .mega: "m.circle.fill"
        case .youtube: "play.rectangle.fill"
        case .arxiv: "doc.text.fill"
        case .twitter: "bubble.left.and.text.bubble.right.fill"
        case .other: "globe"
        }
    }

    var iconImage: NSImage {
        FolderIcons.image(forCategory: self)
    }

    func matches(host: String, url: String) -> Bool {
        let h = host.lowercased()
        let u = url.lowercased()
        switch self {
        case .github:
            return h.contains("github.com") || h.contains("github.io") || h.contains("githubusercontent.com")
        case .drive:
            return h.contains("drive.google.com") || h.contains("docs.google.com")
        case .mega:
            return h.contains("mega.nz") || h.contains("mega.io") || u.contains("mega.nz")
        case .youtube:
            return h.contains("youtube.com") || h.contains("youtu.be")
        case .arxiv:
            return h.contains("arxiv.org")
        case .twitter:
            // Whole domains only: "dropbox.com" contains "x.com" and
            // "microsoft.com" contains "t.co".
            return h.isDomain("x.com") || h.isDomain("twitter.com") || h.isDomain("t.co")
        case .other:
            return !LinkCategory.allCases.filter { $0 != .other }.contains { $0.matches(host: host, url: url) }
        }
    }
}

private extension String {
    /// This host is `domain` or one of its subdomains.
    func isDomain(_ domain: String) -> Bool { self == domain || hasSuffix("." + domain) }
}

// MARK: - Folder Icons & SVGs

enum FolderIcons {
    private static let lock = NSLock()
    private static var cache: [String: NSImage] = [:]

    static func image(forCategory category: LinkCategory) -> NSImage {
        switch category {
        case .github: return get("github", svg: githubSvg)
        case .drive: return get("googledrive", svg: googleDriveSvg)
        case .mega: return get("mega", svg: megaSvg)
        case .youtube: return get("youtube", svg: youtubeSvg)
        case .arxiv: return get("arxiv", svg: arxivSvg)
        case .twitter: return get("twitter", svg: twitterSvg)
        case .other: return get("other", svg: otherSvg)
        }
    }

    static func image(forPlatform platform: Platform) -> NSImage {
        switch platform {
        case .x: return get("twitter", svg: twitterSvg)
        case .github: return get("github", svg: githubSvg)
        case .youtube: return get("youtube", svg: youtubeSvg)
        case .arxiv: return get("arxiv", svg: arxivSvg)
        case .reddit: return get("reddit", svg: redditSvg)
        case .instagram: return get("instagram", svg: instagramSvg)
        case .hackernews: return get("hackernews", svg: hackernewsSvg)
        case .tiktok: return get("tiktok", svg: tiktokSvg)
        case .facebook: return NSImage(systemSymbolName: "person.2", accessibilityDescription: nil) ?? NSImage()
        case .pinterest: return NSImage(systemSymbolName: "pin", accessibilityDescription: nil) ?? NSImage()
        case .web: return get("other", svg: otherSvg)
        }
    }

    static func image(forFolder rawName: String) -> NSImage {
        let normalized = normalize(rawName)
        switch normalized {
        case "bilgi", "bilgiler", "info", "knowledge", "intel":
            return get("bilgi", svg: bilgiSvg)
        case "ders", "dersler", "egitim", "education", "course", "study", "okul":
            return get("ders", svg: dersSvg)
        case "editler", "edit", "montaj", "reels", "editing", "videoedit", "kesit":
            return get("editler", svg: editlerSvg)
        case "gaming", "oyun", "oyunlar", "games", "game", "espor", "gameplay":
            return get("gaming", svg: gamingSvg)
        case "kariyer", "career", "is", "job", "jobs", "cv", "resume":
            return get("kariyer", svg: kariyerSvg)
        case "movies", "film", "filmler", "dizi", "sinema", "cinema", "movie":
            return get("movies", svg: moviesSvg)
        case "nsfw", "18+", "+18", "yetiskin", "adult", "sensitive":
            return get("nsfw", svg: nsfwSvg)
        case "repo", "repos", "github", "git", "kod", "code", "yazilim":
            return get("repo", svg: repoSvg)
        case "saglik", "health", "fitness", "spor", "medikal", "wellness":
            return get("saglik", svg: saglikSvg)
        case "siyaset", "politika", "politics", "gundem", "haber":
            return get("siyaset", svg: siyasetSvg)
        case "ai", "yapayzeka", "model", "llm", "gpt":
            return get("ai", svg: aiSvg)
        case "tasarim", "design", "ui", "ux", "cizim":
            return get("tasarim", svg: tasarimSvg)
        case "muzik", "music", "sarki", "playlist":
            return get("muzik", svg: muzikSvg)
        case "finans", "finance", "para", "kripto", "crypto", "borsa":
            return get("finans", svg: finansSvg)
        case "kitap", "book", "okuma", "roman":
            return get("kitap", svg: kitapSvg)
        case "seyahat", "travel", "gezi", "tatil":
            return get("seyahat", svg: seyahatSvg)
        case "arsiv", "archive", "yedek":
            return get("arsiv", svg: arsivSvg)
        case "favori", "fav", "star", "yildiz":
            return get("favori", svg: favoriSvg)
        default:
            return get("folder", svg: folderSvg)
        }
    }

    private static func normalize(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        s = s.replacingOccurrences(of: "ı", with: "i")
        s = s.replacingOccurrences(of: "ğ", with: "g")
        s = s.replacingOccurrences(of: "ü", with: "u")
        s = s.replacingOccurrences(of: "ş", with: "s")
        s = s.replacingOccurrences(of: "ö", with: "o")
        s = s.replacingOccurrences(of: "ç", with: "c")
        return s
    }

    private static func get(_ key: String, svg: String) -> NSImage {
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache[key] { return existing }
        if let data = svg.data(using: .utf8), let img = NSImage(data: data) {
            img.isTemplate = true
            cache[key] = img
            return img
        }
        let fallback = NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }

    // MARK: - SVG Data Strings

    private static let githubSvg = """
    <svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="black" d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/></svg>
    """

    private static let googleDriveSvg = """
    <svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="black" d="M12.01 1.485c-2.082 0-3.754.02-3.743.047.01.02 1.708 3.001 3.774 6.62l3.76 6.574h3.76c2.081 0 3.753-.02 3.742-.047-.005-.02-1.708-3.001-3.775-6.62l-3.76-6.574zm-4.76 1.73a789.828 789.861 0 0 0-3.63 6.319L0 15.868l1.89 3.298 1.885 3.297 3.62-6.335 3.618-6.33-1.88-3.287C8.1 4.704 7.255 3.22 7.25 3.214zm2.259 12.653-.203.348c-.114.198-.96 1.672-1.88 3.287a423.93 423.948 0 0 1-1.698 2.97c-.01.026 3.24.042 7.222.042h7.244l1.796-3.157c.992-1.734 1.85-3.23 1.906-3.323l.104-.167h-7.249z"/></svg>
    """

    private static let megaSvg = """
    <svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="black" d="M12 0C5.372 0 0 5.372 0 12s5.372 12 12 12 12-5.372 12-12S18.628 0 12 0zm6.23 16.244a.371.371 0 0 1-.373.372H16.29a.371.371 0 0 1-.372-.372v-4.828c0-.04-.046-.06-.08-.033l-3.32 3.32a.742.742 0 0 1-1.043 0l-3.32-3.32c-.027-.027-.08-.007-.08.033v4.828a.371.371 0 0 1-.372.372H6.136a.371.371 0 0 1-.372-.372V7.757c0-.206.166-.372.372-.372h1.076a.75.75 0 0 1 .525.22l4.13 4.13a.18.18 0 0 0 .26 0l4.13-4.13c.14-.14.325-.22.525-.22h1.075c.206 0 .372.166.372.372z"/></svg>
    """

    private static let youtubeSvg = """
    <svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="black" d="M23.498 6.186a3.016 3.016 0 0 0-2.122-2.136C19.505 3.545 12 3.545 12 3.545s-7.505 0-9.377.505A3.017 3.017 0 0 0 .502 6.186C0 8.07 0 12 0 12s0 3.93.502 5.814a3.016 3.016 0 0 0 2.122 2.136c1.871.505 9.376.505 9.376.505s7.505 0 9.377-.505a3.015 3.015 0 0 0 2.122-2.136C24 15.93 24 12 24 12s0-3.93-.502-5.814zM9.545 15.568V8.432L15.818 12l-6.273 3.568z"/></svg>
    """

    private static let arxivSvg = """
    <svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="black" d="M3.8423 0a1.0037 1.0037 0 0 0-.922.6078c-.1536.3687-.0438.6275.2938 1.1113l6.9185 8.3597-1.0223 1.1058a1.0393 1.0393 0 0 0 .003 1.4229l1.2292 1.3135-5.4391 6.4444c-.2803.299-.4538.823-.2971 1.1986a1.0253 1.0253 0 0 0 .9585.635.9133.9133 0 0 0 .6891-.3405l5.783-6.126 7.4902 8.0051a.8527.8527 0 0 0 .6835.2597.9575.9575 0 0 0 .8777-.6138c.1577-.377-.017-.7502-.306-1.1407l-7.0518-8.3418 1.0632-1.13a.9626.9626 0 0 0 .0089-1.3165L4.6336.4639s-.3733-.4535-.768-.463zm0 .272h.0166c.2179.0052.4874.2715.5644.3639l.005.006.0052.0055 10.169 10.9905a.6915.6915 0 0 1-.0072.945l-1.0666 1.133-1.4982-1.7724-8.5994-10.39c-.3286-.472-.352-.6183-.2592-.841a.7307.7307 0 0 1 .6704-.4401Zm14.341 1.5701a.877.877 0 0 0-.6554.2418l-5.6962 6.1584 1.6944 1.8319 5.3089-6.5138c.3251-.4335.479-.6603.3247-1.0292a1.1205 1.1205 0 0 0-.9763-.689zm-7.6557 12.2823 1.3186 1.4135-5.7864 6.1295a.6494.6494 0 0 1-.4959.26.7516.7516 0 0 1-.706-.4669c-.1119-.2682.0359-.6864.2442-.9083l.0051-.0055.0047-.0055z"/></svg>
    """

    private static let twitterSvg = """
    <svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="black" d="M14.234 10.162 22.977 0h-2.072l-7.591 8.824L7.251 0H.258l9.168 13.343L.258 24H2.33l8.016-9.318L16.749 24h6.993zm-2.837 3.299-.929-1.329L3.076 1.56h3.182l5.965 8.532.929 1.329 7.754 11.09h-3.182z"/></svg>
    """

    private static let otherSvg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/><path d="M2 12h20"/></svg>
    """

    private static let bilgiSvg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 14c.2-1 .7-1.7 1.5-2.5 1-.9 1.5-2.2 1.5-3.5A6 6 0 0 0 6 8c0 1 .2 2.2 1.5 3.5.7.7 1.3 1.5 1.5 2.5"/><path d="M9 18h6"/><path d="M10 22h4"/></svg>
    """

    private static let dersSvg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.42 10.922a1 1 0 0 0-.019-1.838L12.83 5.18a2 2 0 0 0-1.66 0L2.6 9.08a1 1 0 0 0 0 1.832l8.57 3.908a2 2 0 0 0 1.66 0z"/><path d="M22 10v6"/><path d="M6 12.5V16a6 3 0 0 0 12 0v-3.5"/></svg>
    """

    private static let editlerSvg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m12.296 3.464 3.02 3.956"/><path d="M20.2 6 3 11l-.9-2.4c-.3-1.1.3-2.2 1.3-2.5l13.5-4c1.1-.3 2.2.3 2.5 1.3z"/><path d="M3 11h18v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><path d="m6.18 5.276 3.1 3.899"/></svg>
    """

    private static let gamingSvg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="6" x2="10" y1="11" y2="11"/><line x1="8" x2="8" y1="9" y2="13"/><line x1="15" x2="15.01" y1="12" y2="12"/><line x1="18" x2="18.01" y1="10" y2="10"/><path d="M17.32 5H6.68a4 4 0 0 0-3.978 3.59c-.006.052-.01.101-.017.152C2.604 9.416 2 14.456 2 16a3 3 0 0 0 3 3c1 0 1.5-.5 2-1l1.414-1.414A2 2 0 0 1 9.828 16h4.344a2 2 0 0 1 1.414.586L17 18c.5.5 1 1 2 1a3 3 0 0 0 3-3c0-1.545-.604-6.584-.685-7.258-.007-.05-.011-.1-.017-.151A4 4 0 0 0 17.32 5z"/></svg>
    """

    private static let kariyerSvg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M16 20V4a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16"/><rect width="20" height="14" x="2" y="6" rx="2"/></svg>
    """

    private static let moviesSvg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="18" height="18" x="3" y="3" rx="2"/><path d="M7 3v18"/><path d="M3 7.5h4"/><path d="M3 12h18"/><path d="M3 16.5h4"/><path d="M17 3v18"/><path d="M17 7.5h4"/><path d="M17 16.5h4"/></svg>
    """

    private static let nsfwSvg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3q1 4 4 6.5t3 5.5a1 1 0 0 1-14 0 5 5 0 0 1 1-3 1 1 0 0 0 5 0c0-2-1.5-3-1.5-5q0-2 2.5-4"/></svg>
    """

    private static let repoSvg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 6a9 9 0 0 0-9 9V3"/><circle cx="18" cy="6" r="3"/><circle cx="6" cy="18" r="3"/></svg>
    """

    private static let saglikSvg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 9.5a5.5 5.5 0 0 1 9.591-3.676.56.56 0 0 0 .818 0A5.49 5.49 0 0 1 22 9.5c0 2.29-1.5 4-3 5.5l-5.492 5.313a2 2 0 0 1-3 .019L5 15c-1.5-1.5-3-3.2-3-5.5"/><path d="M3.22 13H9.5l.5-1 2 4.5 2-7 1.5 3.5h5.27"/></svg>
    """

    private static let siyasetSvg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 18v-7"/><path d="M11.119 2.205a2 2 0 0 1 1.762 0l7.84 3.846A.5.5 0 0 1 20.5 7h-17a.5.5 0 0 1-.22-.949z"/><path d="M14 18v-7"/><path d="M18 18v-7"/><path d="M3 22h18"/><path d="M6 18v-7"/></svg>
    """

    private static let aiSvg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="18" height="18" x="3" y="3" rx="2"/><circle cx="9" cy="9" r="2"/><circle cx="15" cy="9" r="2"/><path d="M8 15h8"/></svg>
    """

    private static let tasarimSvg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="13.5" cy="6.5" r=".5" fill="black"/><circle cx="17.5" cy="10.5" r=".5" fill="black"/><circle cx="8.5" cy="7.5" r=".5" fill="black"/><circle cx="6.5" cy="12.5" r=".5" fill="black"/><path d="M12 2C6.5 2 2 6.5 2 12s4.5 10 10 10c.926 0 1.648-.746 1.648-1.688 0-.437-.18-.835-.437-1.125-.29-.289-.438-.652-.438-1.125a1.64 1.64 0 0 1 1.668-1.668h1.996c3.051 0 5.555-2.503 5.555-5.554C21.965 6.012 17.461 2 12 2z"/></svg>
    """

    private static let muzikSvg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>
    """

    private static let finansSvg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M19 7V4a1 1 0 0 0-1-1H5a2 2 0 0 0 0 4h15a1 1 0 0 1 1 1v4h-3a2 2 0 0 0 0 4h3a1 1 0 0 0 1-1v-2a1 1 0 0 0-1-1"/><path d="M3 5v14a2 2 0 0 0 2 2h15a1 1 0 0 0 1-1v-4"/></svg>
    """

    private static let kitapSvg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z"/><path d="M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z"/></svg>
    """

    private static let seyahatSvg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><polygon points="16.24 7.76 14.12 14.12 7.76 16.24 9.88 9.88 16.24 7.76"/></svg>
    """

    private static let arsivSvg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="20" height="5" x="2" y="3" rx="1"/><path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8"/><path d="M10 12h4"/></svg>
    """

    private static let favoriSvg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/></svg>
    """

    private static let folderSvg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/></svg>
    """

    private static let redditSvg = """
    <svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="black" d="M12 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0zm5.01 4.744c.688 0 1.25.561 1.25 1.249a1.25 1.25 0 0 1-2.498.056l-2.597-.547-.8 3.747c1.824.07 3.48.632 4.674 1.488.308-.309.73-.491 1.207-.491.968 0 1.754.786 1.754 1.754 0 .716-.435 1.333-1.01 1.614a3.111 3.111 0 0 1 .042.52c0 2.694-3.13 4.87-7.004 4.87-3.874 0-7.004-2.176-7.004-4.87 0-.183.015-.366.043-.534A1.748 1.748 0 0 1 4.028 12c0-.968.786-1.754 1.754-1.754.463 0 .898.196 1.207.49 1.207-.883 2.878-1.43 4.744-1.487l.885-4.182a.342.342 0 0 1 .14-.197.35.35 0 0 1 .238-.042l2.906.617a1.214 1.214 0 0 1 1.108-.701zM9.25 12C8.561 12 8 12.562 8 13.25c0 .687.561 1.248 1.25 1.248.687 0 1.248-.561 1.248-1.249 0-.688-.561-1.249-1.249-1.249zm5.5 0c-.687 0-1.248.561-1.248 1.25 0 .687.561 1.248 1.249 1.248.688 0 1.249-.561 1.249-1.249 0-.687-.562-1.249-1.25-1.249zm-5.466 3.99a.327.327 0 0 0-.231.094.33.33 0 0 0 0 .463c.842.842 2.484.913 2.961.913.477 0 2.105-.056 2.961-.913a.361.361 0 0 0 .029-.463.33.33 0 0 0-.464 0c-.547.533-1.684.73-2.512.73-.828 0-1.979-.196-2.512-.73a.326.326 0 0 0-.232-.095z"/></svg>
    """

    private static let instagramSvg = """
    <svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="black" d="M12 2.163c3.204 0 3.584.012 4.85.07 3.252.148 4.771 1.691 4.919 4.919.058 1.265.069 1.645.069 4.849 0 3.205-.012 3.584-.069 4.849-.149 3.225-1.664 4.771-4.919 4.919-1.266.058-1.644.07-4.85.07-3.204 0-3.584-.012-4.849-.07-3.26-.149-4.771-1.699-4.919-4.92-.058-1.265-.07-1.644-.07-4.849 0-3.204.013-3.583.07-4.849.149-3.227 1.664-4.771 4.919-4.919 1.266-.057 1.645-.069 4.849-.069zm0-2.163c-3.259 0-3.667.014-4.947.072-4.358.2-6.78 2.618-6.98 6.98-.059 1.281-.073 1.689-.073 4.948 0 3.259.014 3.668.072 4.948.2 4.358 2.618 6.78 6.98 6.98 1.281.058 1.689.072 4.948.072 3.259 0 3.668-.014 4.948-.072 4.354-.2 6.782-2.618 6.979-6.98.059-1.28.073-1.689.073-4.948 0-3.259-.014-3.667-.072-4.947-.196-4.354-2.617-6.78-6.979-6.98-1.281-.059-1.69-.073-4.949-.073zm0 5.838c-3.403 0-6.162 2.759-6.162 6.162s2.759 6.163 6.162 6.163 6.162-2.759 6.162-6.163c0-3.403-2.759-6.162-6.162-6.162zm0 10.162c-2.209 0-4-1.79-4-4 0-2.209 1.791-4 4-4s4 1.791 4 4c0 2.21-1.791 4-4 4zm6.406-11.845c-.796 0-1.441.645-1.441 1.44s.645 1.44 1.441 1.44c.795 0 1.439-.645 1.439-1.44s-.644-1.44-1.439-1.44z"/></svg>
    """

    private static let hackernewsSvg = """
    <svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="black" d="M0 0v24h24V0H0zm12.9 13.9v5.2h-2v-5.2L7 6.4h2.2l2.8 5.7 2.8-5.7H17l-4.1 7.5z"/></svg>
    """

    private static let tiktokSvg = """
    <svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="black" d="M12.525.02c1.31-.02 2.61-.01 3.91-.02.08 1.53.63 3.09 1.75 4.17 1.12 1.11 2.7 1.62 4.24 1.79v4.03c-1.44-.05-2.89-.35-4.2-.97-.57-.26-1.1-.59-1.62-.93-.01 2.92.01 5.84-.02 8.75-.08 1.4-.54 2.79-1.35 3.94-1.31 1.92-3.58 3.17-5.91 3.21-1.43.08-2.86-.31-4.08-1.03-2.02-1.19-3.44-3.37-3.65-5.71-.02-.5-.03-1-.01-1.49.18-1.9 1.12-3.72 2.58-4.96 1.66-1.44 3.98-2.13 6.15-1.72.02 1.48-.04 2.96-.04 4.44-.99-.32-2.15-.23-3.02.37-.63.41-1.11 1.04-1.36 1.75-.21.51-.24 1.07-.14 1.61.24 1.64 1.82 3.02 3.5 2.87 1.12-.01 2.19-.66 2.77-1.61.19-.33.4-.67.41-1.06.1-1.79.06-3.57.07-5.36.01-4.03-.01-8.05.02-12.07z"/></svg>
    """
}
