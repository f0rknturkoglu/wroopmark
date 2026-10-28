import AppKit
import SwiftUI

enum Theme {
    /// The icon's violet.
    static let accent = Color(red: 0.47, green: 0.29, blue: 0.93)
    /// Content area behind the cards.
    static let canvas = Color(nsColor: .underPageBackgroundColor)
    /// Card surface: white in light mode, raised dark in dark mode.
    static let card = Color(nsColor: .textBackgroundColor)
    static let hairline = Color.primary.opacity(0.08)
    static let cardRadius: CGFloat = 12
    static let cardHeight: CGFloat = 300
    static let coverHeight: CGFloat = 148
    /// The UI is Turkish, so dates are too, whatever the system language.
    static let locale = Locale(identifier: "tr_TR")
}

/// Initial on a colored circle; offline and stable per author.
struct Avatar: View {
    let name: String
    var size: CGFloat = 22

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(initial)
                    .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }

    private var initial: String {
        let clean = name.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
        return clean.first.map { String($0).uppercased() } ?? "?"
    }

    private var color: Color {
        // djb2: Swift's hashValue changes per launch.
        let h = name.unicodeScalars.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ $1.value }
        return Color(hue: Double(h % 360) / 360, saturation: 0.45, brightness: 0.72)
    }
}

extension Date {
    /// "3 sa. önce", "dün", "14 Eki", or "14 Eki 2024" from older years.
    var short: String {
        let age = Date().timeIntervalSince(self)
        if age < 7 * 86_400 {
            let f = RelativeDateTimeFormatter()
            f.locale = Theme.locale
            f.unitsStyle = .short
            f.dateTimeStyle = .named
            return f.localizedString(for: self, relativeTo: Date())
        }
        let sameYear = Calendar.current.isDate(self, equalTo: Date(), toGranularity: .year)
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated).locale(Theme.locale)
        return formatted(sameYear ? style : style.year())
    }
}

/// A tag capsule. Tapping filters the library by it.
struct TagChip: View {
    let name: String
    var selected = false
    var removable = false
    var action: () -> Void = {}
    var remove: () -> Void = {}

    var body: some View {
        HStack(spacing: 3) {
            Button(action: action) {
                Text("#\(name)").lineLimit(1)
            }
            .buttonStyle(.plain)
            if removable {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(selected ? Color.white : Theme.accent)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(selected ? Theme.accent : Theme.accent.opacity(0.12), in: Capsule())
    }
}
