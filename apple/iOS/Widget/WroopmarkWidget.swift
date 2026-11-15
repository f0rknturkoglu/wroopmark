import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// A post from the archive on the home screen. Set it up with a long press
// → Edit Widget: what to show (all, videos, photos), one folder, how often
// it changes; the arrow shows the next one at once. The app writes the
// posts and small pictures in the shared container (`WidgetSnapshot`); the
// widget never opens the library.

struct WidgetPost: Codable, Identifiable {
    let id: String
    let author: String
    let text: String
    let platform: String
    let image: String?
    let video: Bool
    var folder: String?
}

private enum Shared {
    static let group = "group.com.f0rknturkoglu.wroopmark"
    static var dir: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("widget", isDirectory: true)
    }

    static func posts() -> [WidgetPost] {
        guard let url = dir?.appendingPathComponent("posts.json"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([WidgetPost].self, from: data)) ?? []
    }

    static func image(_ name: String?) -> UIImage? {
        guard let name, let url = dir?.appendingPathComponent(name) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// How many times the arrow was tapped (shifts every widget's order).
    static var skip: Int {
        get { UserDefaults(suiteName: group)?.integer(forKey: "widgetSkip") ?? 0 }
        set { UserDefaults(suiteName: group)?.set(newValue, forKey: "widgetSkip") }
    }
}

// MARK: Settings

enum WidgetShow: String, AppEnum {
    case all, videos, photos
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Gösterilen"
    static let caseDisplayRepresentations: [WidgetShow: DisplayRepresentation] = [
        .all: "Hepsi", .videos: "Videolar", .photos: "Fotoğraflar",
    ]
}

enum WidgetEvery: String, AppEnum {
    case quarter, half, hour, threeHours
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sıklık"
    static let caseDisplayRepresentations: [WidgetEvery: DisplayRepresentation] = [
        .quarter: "15 dakikada bir", .half: "30 dakikada bir", .hour: "Saatte bir", .threeHours: "3 saatte bir",
    ]
    var seconds: TimeInterval {
        switch self {
        case .quarter: 900
        case .half: 1800
        case .hour: 3600
        case .threeHours: 10800
        }
    }
}

struct WidgetFolder: AppEntity {
    let id: String
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Klasör"
    static let defaultQuery = WidgetFolderQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id.replacingOccurrences(of: "/", with: " › "))") }
}

struct WidgetFolderQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetFolder] { identifiers.map(WidgetFolder.init) }

    /// The folders the app wrote posts for.
    func suggestedEntities() async throws -> [WidgetFolder] {
        Set(Shared.posts().compactMap(\.folder)).sorted().map(WidgetFolder.init)
    }
}

struct WidgetSettings: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Arşivinden"
    static let description = IntentDescription("Kaydettiklerinden biri.")

    @Parameter(title: "Göster", default: .all) var show: WidgetShow
    @Parameter(title: "Klasör") var folder: WidgetFolder?
    @Parameter(title: "Değişsin", default: .hour) var every: WidgetEvery
}

/// The arrow on the widget: the next post now.
struct NextPostIntent: AppIntent {
    static let title: LocalizedStringResource = "Sonraki kayıt"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        Shared.skip += 1
        return .result()
    }
}

// MARK: Timeline

struct PostEntry: TimelineEntry {
    let date: Date
    let post: WidgetPost?
    var note: String?
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PostEntry {
        PostEntry(date: .now, post: WidgetPost(id: "", author: "wroopmark", text: "Kaydettiklerinden biri burada.", platform: "web", image: nil, video: false))
    }

    func snapshot(for configuration: WidgetSettings, in context: Context) async -> PostEntry {
        PostEntry(date: .now, post: Self.posts(for: configuration).first ?? placeholder(in: context).post)
    }

    func timeline(for configuration: WidgetSettings, in context: Context) async -> Timeline<PostEntry> {
        let posts = Self.posts(for: configuration)
        guard !posts.isEmpty else {
            let note = Shared.posts().isEmpty ? "wroopmark'ı bir kez aç" : "Bu seçimde kayıt yok"
            return Timeline(entries: [PostEntry(date: .now, post: nil, note: note)], policy: .after(.now.addingTimeInterval(3600)))
        }
        // From now on, one post per step; the arrow moves the start along.
        let step = configuration.every.seconds
        let start = posts.count > 1 ? Shared.skip % posts.count : 0
        let count = min(posts.count, 48)
        let entries = (0..<count).map { i in
            PostEntry(date: .now.addingTimeInterval(Double(i) * step), post: posts[(start + i) % posts.count])
        }
        return Timeline(entries: entries, policy: .atEnd)
    }

    private static func posts(for c: WidgetSettings) -> [WidgetPost] {
        Shared.posts().filter { p in
            switch c.show {
            case .all: break
            case .videos: if !p.video { return false }
            case .photos: if p.video { return false }
            }
            if let f = c.folder?.id { return p.folder == f || p.folder?.hasPrefix(f + "/") == true }
            return true
        }
    }
}

// MARK: View

struct PostView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PostEntry

    var body: some View {
        if let post = entry.post {
            let image = Shared.image(post.image)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top) {
                    if post.video {
                        Image(systemName: "play.fill").font(.caption2).padding(5).background(.ultraThinMaterial, in: .circle)
                    }
                    Spacer()
                    Button(intent: NextPostIntent()) {
                        Image(systemName: "arrow.forward").font(.caption2.weight(.bold)).padding(6).background(.ultraThinMaterial, in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Sonraki")
                }
                Spacer(minLength: 0)
                Text(post.author).font(.caption.weight(.semibold)).lineLimit(1)
                if family != .systemSmall || image == nil, !post.text.isEmpty {
                    Text(post.text)
                        .font(family == .systemLarge ? .callout : .caption)
                        .lineLimit(family == .systemLarge ? 5 : 3)
                }
            }
            .foregroundStyle(image == nil ? Color.primary : .white)
            .shadow(color: image == nil ? .clear : .black.opacity(0.7), radius: 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(for: .widget) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .overlay { LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom) }
                } else {
                    LinearGradient(colors: [Color(red: 0.47, green: 0.29, blue: 0.93).opacity(0.25), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .widgetURL(URL(string: "wroopmark://item/\(post.id)"))
        } else {
            VStack(spacing: 6) {
                Image(systemName: "bookmark").font(.title2)
                Text(entry.note ?? "wroopmark'ı bir kez aç").font(.caption).multilineTextAlignment(.center)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

struct RandomPostWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "random-post", intent: WidgetSettings.self, provider: Provider()) { PostView(entry: $0) }
            .configurationDisplayName("Arşivinden")
            .description("Kaydettiklerinden biri. Uzun bas → Widget'ı Düzenle: ne gösterileceği, klasör, sıklık.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct WroopmarkWidgets: WidgetBundle {
    var body: some Widget {
        RandomPostWidget()
    }
}
