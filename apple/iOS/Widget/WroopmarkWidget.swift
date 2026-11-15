import SwiftUI
import UIKit
import WidgetKit

// A post from the archive on the home screen, a different one every hour.
// The app writes a few posts and small pictures for it in the shared
// container (`WidgetSnapshot`); the widget never opens the library.

struct WidgetPost: Codable, Identifiable {
    let id: String
    let author: String
    let text: String
    let platform: String
    let image: String?
    let video: Bool
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
}

struct PostEntry: TimelineEntry {
    let date: Date
    let post: WidgetPost?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> PostEntry {
        PostEntry(date: .now, post: WidgetPost(id: "", author: "wroopmark", text: "Kaydettiklerinden biri burada.", platform: "web", image: nil, video: false))
    }

    func getSnapshot(in context: Context, completion: @escaping (PostEntry) -> Void) {
        completion(PostEntry(date: .now, post: Shared.posts().first ?? placeholder(in: context).post))
    }

    /// One post an hour, then the app's next set.
    func getTimeline(in context: Context, completion: @escaping (Timeline<PostEntry>) -> Void) {
        let posts = Shared.posts()
        guard !posts.isEmpty else {
            completion(Timeline(entries: [PostEntry(date: .now, post: nil)], policy: .after(.now.addingTimeInterval(3600))))
            return
        }
        let start = Calendar.current.dateInterval(of: .hour, for: .now)?.start ?? .now
        let entries = posts.enumerated().map { i, p in PostEntry(date: start.addingTimeInterval(Double(i) * 3600), post: p) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct PostView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PostEntry

    var body: some View {
        if let post = entry.post {
            let image = Shared.image(post.image)
            VStack(alignment: .leading, spacing: 3) {
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
            .overlay(alignment: .topTrailing) {
                if post.video {
                    Image(systemName: "play.fill").font(.caption2).padding(5).background(.ultraThinMaterial, in: .circle)
                }
            }
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
                Text("wroopmark'ı bir kez aç").font(.caption).multilineTextAlignment(.center)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

struct RandomPostWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "random-post", provider: Provider()) { PostView(entry: $0) }
            .configurationDisplayName("Arşivinden")
            .description("Kaydettiklerinden biri; saatte bir değişir.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct WroopmarkWidgets: WidgetBundle {
    var body: some Widget {
        RandomPostWidget()
    }
}
