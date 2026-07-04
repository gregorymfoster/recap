import SwiftUI
import Testing
@testable import RecapUI

@Suite struct DesignTokenTests {
    @Test @MainActor func tokensResolveToExpectedHex() {
        #expect(Tokens.textPrimary.resolvedHex == "1C1C1E")
        #expect(Tokens.accentBlue.resolvedHex == "0A84FF")
        #expect(Tokens.recordRed.resolvedHex == "FF453A")
    }
}

extension Color {
    /// Hex string of the color's sRGB components, for token verification.
    var resolvedHex: String {
        let resolved = self.resolve(in: EnvironmentValues())
        let r = Int((resolved.red * 255).rounded())
        let g = Int((resolved.green * 255).rounded())
        let b = Int((resolved.blue * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }
}
