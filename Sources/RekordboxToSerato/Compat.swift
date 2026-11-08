import SwiftUI

// Liquid Glass on macOS 26 and later, the classic look on macOS 14/15 (Sonoma, Sequoia).
//
// Apple's guidance this follows:
// • Glass belongs to the navigation/control layer that floats above content
//   (toolbars, sidebars, inspectors, floating bars), never to the content itself.
// • Prefer system components: they adopt glass automatically when built with the
//   new SDK and keep their classic appearance on older systems.
// • Use tinted ("prominent") glass only for the one primary action.
// • Don't stack glass on glass: controls inside a glass surface stay plain.

extension View {
    /// The single most important action on screen (tinted glass / bordered prominent).
    @ViewBuilder func adaptivePrimaryButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// A secondary action that sits directly on content (not inside a toolbar or another glass surface).
    @ViewBuilder func adaptiveSecondaryButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// A floating control surface: Liquid Glass on macOS 26+, a translucent material panel before.
    @ViewBuilder func adaptiveGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        }
    }
}
