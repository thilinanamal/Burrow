import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case clean = "Clean"
    case apps = "Apps"
    case optimize = "Optimize"
    case analyze = "Analyze"
    case status = "Status"

    var id: String { rawValue }

    /// Each tab gets its own sky, top to bottom.
    var background: [Color] {
        switch self {
        case .clean: return [Color(hex: 0x29324D), Color(hex: 0x1D2134)]
        case .apps: return [Color(hex: 0x3E1E20), Color(hex: 0x2A1415)]
        case .optimize: return [Color(hex: 0x3A3532), Color(hex: 0x272523)]
        case .analyze: return [Color(hex: 0x4D2F1F), Color(hex: 0x2F1C13)]
        case .status: return [Color(hex: 0x4B3B1F), Color(hex: 0x2E2514)]
        }
    }

    var accent: Color {
        switch self {
        case .clean: return Color(hex: 0x8FB4FF)
        case .apps: return Color(hex: 0xE58A80)
        case .optimize: return Color(hex: 0xD9D2C8)
        case .analyze: return Color(hex: 0xE3A766)
        case .status: return Color(hex: 0x86C79A)
        }
    }

    var card: Color {
        switch self {
        case .clean: return Color.white.opacity(0.06)
        case .apps: return Color.white.opacity(0.05)
        case .optimize: return Color.white.opacity(0.05)
        case .analyze: return Color.white.opacity(0.06)
        case .status: return Color.white.opacity(0.06)
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    static let goodGreen = Color(hex: 0x5BC48A)
    static let warnAmber = Color(hex: 0xE6B655)
    static let dangerRed = Color(hex: 0xE5675C)
}

extension Font {
    /// Serif used for the short verses under each planet.
    static func verse(_ size: CGFloat = 16) -> Font { .system(size: size, weight: .regular, design: .serif) }
    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// White pill button used for the main action on each screen.
struct PrimaryPillStyle: ButtonStyle {
    var width: CGFloat? = 250
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.black)
            .frame(width: width, height: 50)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.8 : 1)))
            .shadow(color: .white.opacity(0.18), radius: 18)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SubtleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.6 : 0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

struct Card<Content: View>: View {
    var tab: AppTab
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tab.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }
}

struct Chip: View {
    var text: String
    var tint: Color = .white
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint.opacity(0.9))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.12)))
    }
}
