import AppKit
import SwiftUI

enum Theme {
    /// The app's single accent. Everything tintable uses it; nothing else
    /// defines its own palette.
    static let accent = Color(red: 0.47, green: 0.29, blue: 0.93)
    /// The UI is Turkish, so dates are too, whatever the system language.
    static let locale = Locale(identifier: "tr_TR")

    /// Strict 4pt / 8pt spatial rhythm across all views.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    /// Concentric corner radii: outer card (`24`) = inner (`8`) + padding (`16`),
    /// medium panels (`16`) = inner (`8`) + padding (`8`).
    enum Radius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
    }

    /// Window geometry shared by the split view and the views that have to
    /// line up with it. Keeping these here stops the columns from drifting
    /// apart when one screen is resized.
    enum Layout {
        static let sidebarMinWidth: CGFloat = 220
        static let sidebarIdealWidth: CGFloat = 250
        static let sidebarMaxWidth: CGFloat = 320

        static let inspectorMinWidth: CGFloat = 300
        static let inspectorIdealWidth: CGFloat = 340
        static let inspectorMaxWidth: CGFloat = 520

        /// Narrowest usable card; cards divide the remaining width evenly.
        static let cardMinWidth: CGFloat = 260
        /// Reading measure for the detail column and the feed.
        static let readingWidth: CGFloat = 660
    }

    enum Stroke {
        static let hairlineWidth: CGFloat = 0.5
        static let selectionWidth: CGFloat = 2
        static let surfaceBorder = Color.primary.opacity(0.08)
        static let surfaceHoverBorder = Color.primary.opacity(0.16)
        static let subtleFill = Color.primary.opacity(0.04)
        static let subtleHoverFill = Color.primary.opacity(0.08)
        static let mediaOutline = Color.primary.opacity(0.08)
        static let darkOverlayBorder = Color.white.opacity(0.14)
    }
}

/// Initial on an accent-tinted circle.
struct Avatar: View {
    let name: String
    var size: CGFloat = 24

    var body: some View {
        Circle()
            .fill(Theme.accent.opacity(0.16))
            .frame(width: size, height: size)
            .overlay {
                Circle()
                    .strokeBorder(Theme.accent.opacity(0.24), lineWidth: Theme.Stroke.hairlineWidth)
            }
            .overlay {
                Text(initial)
                    .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent)
            }
    }

    private var initial: String {
        let clean = name.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
        return clean.first.map { String($0).uppercased() } ?? "?"
    }
}

extension Date {
    /// Built once: every card asks for its date on every redraw.
    @MainActor
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Theme.locale
        f.unitsStyle = .short
        f.dateTimeStyle = .named
        return f
    }()
    private static let dayMonth = Date.FormatStyle.dateTime.day().month(.abbreviated).locale(Theme.locale)
    private static let dayMonthYear = dayMonth.year()

    @MainActor private static var cachedDayKey: Int = .min
    @MainActor private static var cachedYear: Int = .min
    @MainActor private static var shortDateCache: [Int64: String] = [:]

    /// "3 sa. önce", "dün", "14 Eki", or "14 Eki 2024" from older years.
    @MainActor
    var short: String {
        let now = Date()
        let delta = now.timeIntervalSince(self)
        let bucket = Int64(timeIntervalSince1970 / 60)
        let dayKey = Int(now.timeIntervalSince1970 / 60) // minute-level bucket invalidates relative labels cleanly
        if Self.cachedDayKey != dayKey {
            Self.cachedDayKey = dayKey
            Self.cachedYear = Calendar.current.component(.year, from: now)
            if Self.shortDateCache.count > 512 {
                Self.shortDateCache.removeAll(keepingCapacity: true)
            } else if delta < 7 * 86_400 {
                // Only clear relative strings when minute advances; simpler & fast to clear bounded cache
                Self.shortDateCache.removeAll(keepingCapacity: true)
            }
        }
        if let cached = Self.shortDateCache[bucket] {
            return cached
        }
        let formattedValue: String
        if delta < 7 * 86_400 {
            formattedValue = Self.relative.localizedString(for: self, relativeTo: now)
        } else {
            let sameYear = Calendar.current.component(.year, from: self) == Self.cachedYear
            formattedValue = formatted(sameYear ? Self.dayMonth : Self.dayMonthYear)
        }
        if Self.shortDateCache.count >= 512 {
            Self.shortDateCache.removeAll(keepingCapacity: true)
        }
        Self.shortDateCache[bucket] = formattedValue
        return formattedValue
    }
}

/// A tag capsule. Tapping filters the library by it.
struct TagChip: View {
    let name: String
    var selected = false
    var removable = false
    var action: () -> Void = {}
    var remove: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            // The padding belongs to the button so the whole capsule body is
            // clickable, not only the few points covered by the glyphs.
            Button(action: action) {
                Text("#\(name)")
                    .lineLimit(1)
                    .padding(.vertical, Theme.Spacing.xs)
                    .padding(.leading, Theme.Spacing.sm)
                    .padding(.trailing, removable ? 0 : Theme.Spacing.sm)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if removable {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Color.white.opacity(0.88) : Color.secondary)
                .padding(.trailing, Theme.Spacing.sm)
                .accessibilityLabel("Etiketi kaldır: #\(name)")
            }
        }
        .font(.caption.weight(.medium))
        .controlSize(.small)
        .foregroundStyle(selected ? Color.white : Theme.accent)
        .background(
            selected
                ? (hovering ? Theme.accent.opacity(0.92) : Theme.accent)
                : Theme.accent.opacity(hovering ? 0.18 : 0.12),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .strokeBorder(
                    selected ? Color.white.opacity(0.16) : Theme.accent.opacity(hovering ? 0.36 : 0.18),
                    lineWidth: Theme.Stroke.hairlineWidth
                )
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Quiet count for bars and cards: monospaced, secondary, and small enough
/// to sit beside a title without pulling the eye.
struct CountPill: View {
    let value: String

    var body: some View {
        Text(value)
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Theme.Stroke.subtleFill, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Theme.Stroke.surfaceBorder, lineWidth: Theme.Stroke.hairlineWidth)
            }
    }
}
