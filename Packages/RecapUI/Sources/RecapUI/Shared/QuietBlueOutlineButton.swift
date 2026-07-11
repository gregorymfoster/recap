import SwiftUI

/// A quiet, outlined text button: thin blue border, blue text, no fill.
/// Used for secondary actions that shouldn't compete with a primary
/// filled/tinted button (Phase 1 redesign).
public struct QuietBlueOutlineButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Self.textColor)
            .padding(.vertical, 3)
            .padding(.horizontal, 10)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Self.strokeColor, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.6 : 1)
    }

    static let strokeColor = Tokens.accentBlueText.opacity(0.4)
    static let textColor = Tokens.accentBlueText
}

extension ButtonStyle where Self == QuietBlueOutlineButtonStyle {
    public static var quietBlueOutline: QuietBlueOutlineButtonStyle { QuietBlueOutlineButtonStyle() }
}
