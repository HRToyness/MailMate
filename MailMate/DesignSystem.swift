import AppKit
import SwiftUI

// MARK: - Color tokens

enum MMColor {
    /// Primary gradient start — matches the app icon's top.
    static let indigo = Color(red: 0.36, green: 0.43, blue: 0.95)
    /// Primary gradient end — matches the app icon's bottom.
    static let violet = Color(red: 0.55, green: 0.32, blue: 0.90)
    /// Accent highlight — sparkle gold.
    static let gold = Color(red: 1.00, green: 0.82, blue: 0.48)
    /// Subtle separator / hairline.
    static let hairline = Color.primary.opacity(0.08)
}

extension LinearGradient {
    static let mmBrand = LinearGradient(
        colors: [MMColor.indigo, MMColor.violet],
        startPoint: .top,
        endPoint: .bottom
    )

    static let mmBrandDiagonal = LinearGradient(
        colors: [MMColor.indigo, MMColor.violet],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Typography helpers

enum MMFont {
    static let display = Font.system(size: 22, weight: .bold, design: .rounded)
    static let title   = Font.system(size: 17, weight: .semibold)
    static let body    = Font.system(size: 13)
    static let caption = Font.system(size: 11)
    static let label   = Font.system(size: 10, weight: .bold)
}

// MARK: - Spacing tokens

enum MMSpace {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    static let md: CGFloat = 16
    static let lg: CGFloat = 22
    static let xl: CGFloat = 32
}

// MARK: - Vibrancy background (translucent macOS-native)

struct VibrancyBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Modifiers

struct MMPanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background(VibrancyBackground().ignoresSafeArea())
    }
}

struct MMCardStyle: ViewModifier {
    var padding: CGFloat = MMSpace.md
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(MMColor.hairline, lineWidth: 1)
            )
    }
}

struct MMTextAreaStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(MMColor.hairline, lineWidth: 1)
            )
    }
}

extension View {
    /// Apply the app's vibrancy panel background to the root of a floating window.
    func mmPanelBackground() -> some View { modifier(MMPanelBackground()) }
    /// Apply the standard card treatment (translucent surface + hairline stroke + rounded-12).
    func mmCard(padding: CGFloat = MMSpace.md) -> some View { modifier(MMCardStyle(padding: padding)) }
    /// Apply the standard text-area treatment (textBackground surface + hairline + rounded-10).
    func mmTextArea() -> some View { modifier(MMTextAreaStyle()) }
}

// MARK: - Button styles

struct MMPrimaryButtonStyle: ButtonStyle {
    var compact: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 6 : 9)
            .background(
                RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous)
                    .fill(LinearGradient.mmBrand)
            )
            .shadow(color: MMColor.indigo.opacity(0.35), radius: configuration.isPressed ? 4 : 10, y: 2)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

struct MMGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06))
            )
            .animation(.snappy(duration: 0.10), value: configuration.isPressed)
    }
}

// MARK: - Section label (small-caps with gradient bar)

struct MMSectionLabel: View {
    let text: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(LinearGradient.mmBrand)
                .frame(width: 3, height: 12)
            if let icon {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(LinearGradient.mmBrand)
            }
            Text(text.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.secondary)
                .tracking(1.8)
        }
    }
}

// MARK: - Gradient-filled envelope glyph for panel headers

struct MMBrandGlyph: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient.mmBrand)
                .shadow(color: MMColor.indigo.opacity(0.3), radius: size * 0.3, y: 2)
            Image(systemName: "envelope.badge.fill")
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Pill badge (for priority, tags, etc.)

struct MMPill: View {
    let text: String
    var color: Color = MMColor.indigo

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(color.opacity(0.15))
            )
            .overlay(
                Capsule().stroke(color.opacity(0.25), lineWidth: 1)
            )
    }
}
