import AppKit
import SwiftUI

// Shared building blocks for the flat, sidebar-driven chrome. Everything uses system
// semantic colours so light and dark appearances come for free.

enum Chrome {
    static let sidebarWidth: CGFloat = 248
    static let panelWidth: CGFloat = 380
    static let pipelinePanelWidth: CGFloat = 520
    /// Narrowest usable document area (tabs + Format/Clean + view switcher).
    static let minDocumentWidth: CGFloat = 560
    static let headerHeight: CGFloat = 52
    static let tabBarHeight: CGFloat = 44
    static let statusBarHeight: CGFloat = 26
    static let cornerRadius: CGFloat = 8
    /// Space reserved for the traffic lights when they sit inside our chrome.
    static let trafficLightInset: CGFloat = 78

    static var sidebarBackground: Color { adaptive(light: 0xF5F5F6, dark: 0x1F1F21) }
    static var contentBackground: Color { adaptive(light: 0xFFFFFF, dark: 0x171718) }
    static var panelBackground: Color { adaptive(light: 0xFFFFFF, dark: 0x2A2A2D) }

    /// A colour that resolves per appearance (light/dark) at draw time.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
    static var hairline: Color { Color(nsColor: .separatorColor) }
    static var fill: Color { Color.primary.opacity(0.06) }
    static var fillHover: Color { Color.primary.opacity(0.09) }
    static var selection: Color { Color.primary.opacity(0.08) }
    static var hover: Color { Color.primary.opacity(0.045) }

    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let rowFont = Font.system(size: 13)
    static let captionFont = Font.system(size: 11)
    static let sectionFont = Font.system(size: 11, weight: .semibold)
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Tracks pointer hover for custom rows and buttons.
struct HoverTracking: ViewModifier {
    @Binding var isHovering: Bool
    func body(content: Content) -> some View {
        content.onHover { isHovering = $0 }
    }
}

/// A borderless icon button with a soft hover highlight.
struct IconButton: View {
    let systemImage: String
    var help: String = ""
    var size: CGFloat = 28
    var isActive = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? Chrome.selection : (hovering ? Chrome.hover : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// A compact text+icon button used in the tab bar ("Format", "Clean").
struct ChromeButton: View {
    let title: String
    let systemImage: String
    var help: String = ""
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 12, weight: .medium))
                Text(title).font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Chrome.fillHover : Chrome.fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// Segmented "pill" control (Text | Path, Schema | Results, …).
struct PillSegmented<T: Hashable>: View {
    struct Segment {
        let value: T
        let title: String
        var systemImage: String? = nil
        var badge: Int? = nil
    }

    let segments: [Segment]
    @Binding var selection: T
    var iconOnly = false
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                let selected = segment.value == selection
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = segment.value }
                } label: {
                    HStack(spacing: 5) {
                        if let icon = segment.systemImage {
                            Image(systemName: icon).font(.system(size: 11.5, weight: .medium))
                        }
                        if !iconOnly {
                            Text(segment.title).font(.system(size: 12, weight: .medium))
                        }
                        if let badge = segment.badge, badge > 0 {
                            Text("\(badge)")
                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Chrome.fill))
                        }
                    }
                    .foregroundStyle(selected ? .primary : .secondary)
                    .padding(.horizontal, iconOnly ? 8 : 10)
                    .frame(height: 24)
                    .frame(maxWidth: iconOnly ? nil : .infinity)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Chrome.panelBackground)
                                .shadow(color: .black.opacity(0.10), radius: 1.5, y: 0.5)
                                .matchedGeometryEffect(id: "pill", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(segment.title)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Chrome.fill))
    }
}

/// Rounded search field matching the sidebar style.
struct SearchPill: View {
    let placeholder: String
    @Binding var text: String
    var systemImage = "magnifyingglass"
    var monospaced = false
    var hasError = false
    var focus: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(monospaced ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
                .focused(focus)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: Chrome.cornerRadius, style: .continuous).fill(Chrome.fill))
        .overlay(
            RoundedRectangle(cornerRadius: Chrome.cornerRadius, style: .continuous)
                .strokeBorder(hasError ? Color.red.opacity(0.6) : (focus.wrappedValue ? Color.accentColor.opacity(0.5) : .clear), lineWidth: 1)
        )
    }
}

/// Sidebar section title with an optional trailing accessory.
struct SectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(Chrome.sectionFont)
                .foregroundStyle(.secondary)
                .kerning(0.4)
            Spacer()
            accessory
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

/// A selectable sidebar row: leading dot/icon, title, subtitle, trailing accessory.
struct SidebarRow<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var isSelected = false
    var action: () -> Void
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                leading.frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Chrome.rowFont).lineLimit(1).truncationMode(.middle)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(Chrome.captionFont).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                trailing
            }
            .padding(.horizontal, 8)
            .padding(.vertical, subtitle == nil ? 6 : 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Chrome.selection : (hovering ? Chrome.hover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }
}

/// Small coloured status dot.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}

/// Thin separator line.
struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle()
            .fill(Chrome.hairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Compact empty/placeholder state that always fills its container and stays centred,
/// in the same visual language as the rest of the chrome.
struct EmptyState<Actions: View>: View {
    let systemImage: String
    let title: String
    var message: String? = nil
    var tint: Color = .secondary
    @ViewBuilder var actions: Actions

    init(systemImage: String, title: String, message: String? = nil, tint: Color = .secondary, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.tint = tint
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(tint == .secondary ? Color.secondary.opacity(0.6) : tint)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            if let message {
                Text(message)
                    .font(Chrome.captionFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) { actions }
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
