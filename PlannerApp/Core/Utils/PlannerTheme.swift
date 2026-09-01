import SwiftUI

enum PlannerTheme {
    static let windowBackground = Color(red: 0.035, green: 0.050, blue: 0.070)
    static let sidebarBackground = Color(red: 0.045, green: 0.065, blue: 0.090)
    static let panelBackground = Color(red: 0.065, green: 0.090, blue: 0.125)
    static let elevatedBackground = Color(red: 0.080, green: 0.110, blue: 0.155)
    static let rowBackground = Color(red: 0.060, green: 0.085, blue: 0.120)
    static let rowHoverBackground = Color(red: 0.085, green: 0.125, blue: 0.175)
    static let border = Color(red: 0.170, green: 0.215, blue: 0.285)
    static let subtleBorder = Color(red: 0.125, green: 0.160, blue: 0.215)
    static let accent = Color(red: 0.185, green: 0.500, blue: 1.000)
    static let accentStrong = Color(red: 0.120, green: 0.380, blue: 0.900)
    static let accentSoft = Color(red: 0.090, green: 0.230, blue: 0.440)
    static let success = Color(red: 0.220, green: 0.680, blue: 1.000)
    static let warning = Color(red: 1.000, green: 0.650, blue: 0.180)
    static let danger = Color(red: 1.000, green: 0.310, blue: 0.300)
    static let secondaryText = Color(red: 0.600, green: 0.670, blue: 0.760)

    static func projectAccent(_ preset: ProjectColorPreset) -> Color {
        switch preset {
        case .ocean:
            Color(red: 0.185, green: 0.500, blue: 1.000)
        case .sky:
            Color(red: 0.300, green: 0.760, blue: 1.000)
        case .violet:
            Color(red: 0.620, green: 0.420, blue: 1.000)
        case .rose:
            Color(red: 1.000, green: 0.330, blue: 0.600)
        case .amber:
            Color(red: 1.000, green: 0.650, blue: 0.180)
        case .emerald:
            Color(red: 0.180, green: 0.760, blue: 0.430)
        case .mint:
            Color(red: 0.180, green: 0.850, blue: 0.760)
        case .graphite:
            Color(red: 0.520, green: 0.600, blue: 0.700)
        case .sunset:
            Color(red: 1.000, green: 0.420, blue: 0.220)
        case .aurora:
            Color(red: 0.320, green: 0.840, blue: 0.960)
        }
    }

    static func projectGradient(_ preset: ProjectColorPreset, opacity: Double = 0.22) -> LinearGradient {
        let colors: [Color]

        switch preset {
        case .ocean:
            colors = [
                Color(red: 0.120, green: 0.360, blue: 0.900).opacity(opacity),
                Color(red: 0.160, green: 0.680, blue: 1.000).opacity(opacity * 0.78)
            ]
        case .sky:
            colors = [
                Color(red: 0.220, green: 0.660, blue: 1.000).opacity(opacity),
                Color(red: 0.420, green: 0.900, blue: 1.000).opacity(opacity * 0.78)
            ]
        case .violet:
            colors = [
                Color(red: 0.460, green: 0.260, blue: 1.000).opacity(opacity),
                Color(red: 0.820, green: 0.420, blue: 1.000).opacity(opacity * 0.78)
            ]
        case .rose:
            colors = [
                Color(red: 1.000, green: 0.240, blue: 0.520).opacity(opacity),
                Color(red: 1.000, green: 0.500, blue: 0.740).opacity(opacity * 0.78)
            ]
        case .amber:
            colors = [
                Color(red: 1.000, green: 0.560, blue: 0.120).opacity(opacity),
                Color(red: 1.000, green: 0.820, blue: 0.260).opacity(opacity * 0.78)
            ]
        case .emerald:
            colors = [
                Color(red: 0.120, green: 0.620, blue: 0.360).opacity(opacity),
                Color(red: 0.220, green: 0.860, blue: 0.520).opacity(opacity * 0.78)
            ]
        case .mint:
            colors = [
                Color(red: 0.120, green: 0.740, blue: 0.680).opacity(opacity),
                Color(red: 0.360, green: 0.940, blue: 0.820).opacity(opacity * 0.78)
            ]
        case .graphite:
            colors = [
                Color(red: 0.280, green: 0.340, blue: 0.440).opacity(opacity),
                Color(red: 0.560, green: 0.640, blue: 0.760).opacity(opacity * 0.72)
            ]
        case .sunset:
            colors = [
                Color(red: 1.000, green: 0.320, blue: 0.180).opacity(opacity),
                Color(red: 1.000, green: 0.740, blue: 0.260).opacity(opacity * 0.78)
            ]
        case .aurora:
            colors = [
                Color(red: 0.160, green: 0.820, blue: 0.780).opacity(opacity),
                Color(red: 0.420, green: 0.440, blue: 1.000).opacity(opacity * 0.78)
            ]
        }

        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct GlassHoverIconButtonStyle: ButtonStyle {
    let size: CGFloat
    var tint: Color = PlannerTheme.accent
    var isProminent = false
    var isEnabled = true
    var appliesEffect = true

    func makeBody(configuration: Configuration) -> some View {
        GlassHoverIconButton(
            configuration: configuration,
            size: size,
            tint: tint,
            isProminent: isProminent,
            isEnabled: isEnabled,
            appliesEffect: appliesEffect
        )
    }
}

private struct GlassHoverIconButton: View {
    let configuration: ButtonStyle.Configuration
    let size: CGFloat
    let tint: Color
    let isProminent: Bool
    let isEnabled: Bool
    let appliesEffect: Bool

    @State private var isHovered = false

    private var interactionAmount: Double {
        if configuration.isPressed { return 1 }
        if isHovered { return 0.72 }
        return 0
    }

    @ViewBuilder
    var body: some View {
        if appliesEffect {
            glassButton
        } else {
            configuration.label
        }
    }

    private var glassButton: some View {
        configuration.label
            .frame(width: size, height: size)
            .foregroundStyle(foregroundColor)
            .background {
                GlassHoverButtonBackground(
                    tint: tint,
                    backgroundColor: backgroundColor,
                    isProminent: isProminent,
                    isHovered: isHovered,
                    interactionAmount: interactionAmount
                )
            }
            .scaleEffect(configuration.isPressed ? 0.94 : (isHovered ? 1.055 : 1))
            .contentShape(Circle())
            .onHover { hovering in
                isHovered = hovering && isEnabled
            }
            .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.76), value: isHovered)
            .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.70), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        guard isEnabled else { return PlannerTheme.secondaryText.opacity(0.48) }
        return isProminent ? .white : tint
    }

    private var backgroundColor: Color {
        guard isEnabled else {
            return isProminent ? PlannerTheme.elevatedBackground.opacity(0.72) : .clear
        }
        if isProminent {
            return tint.opacity(configuration.isPressed ? 0.78 : 0.96)
        }
        return tint.opacity(interactionAmount * 0.16)
    }
}

private struct GlassHoverButtonBackground: View {
    let tint: Color
    let backgroundColor: Color
    let isProminent: Bool
    let isHovered: Bool
    let interactionAmount: Double

    private var highlightOpacity: Double {
        isProminent || isHovered ? 1 : 0
    }

    private var borderOpacity: Double {
        isProminent ? 0.20 + interactionAmount * 0.10 : interactionAmount * 0.16
    }

    private var shadowOpacity: Double {
        isProminent ? 0.16 + interactionAmount * 0.22 : interactionAmount * 0.18
    }

    var body: some View {
        Circle()
            .fill(backgroundColor)
            .overlay(highlight)
            .overlay(border)
            .shadow(
                color: tint.opacity(shadowOpacity),
                radius: 4 + interactionAmount * 5,
                y: 1 + interactionAmount
            )
    }

    private var highlight: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(isProminent ? 0.20 : 0.10), Color.white.opacity(0.01)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .opacity(highlightOpacity)
    }

    private var border: some View {
        Circle()
            .strokeBorder(Color.white.opacity(borderOpacity), lineWidth: 0.75)
    }
}
