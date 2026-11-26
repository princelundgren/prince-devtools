import SwiftUI

/// A card's state. Each tone has its own symbol, so the state never rests on colour alone.
public enum PanelTone: Sendable {
    /// No reading yet; neutral, never green or red.
    case notKnown
    /// A reading that reports without judging; neither green nor red.
    case info
    case green
    case yellow
    case red

    /// The SF Symbol that marks this tone.
    public var symbolName: String {
        switch self {
        case .notKnown: "circle.dashed"
        case .info: "info.circle.fill"
        case .green: "checkmark.circle.fill"
        case .yellow: "exclamationmark.triangle.fill"
        case .red: "exclamationmark.octagon.fill"
        }
    }

    /// The tone's colour, from the module's asset catalog; `.secondary` for ``notKnown``.
    public var color: Color {
        switch self {
        case .notKnown: .secondary
        case .info: Color("Blue", bundle: .module)
        case .green: Color("Green", bundle: .module)
        case .yellow: Color("Yellow", bundle: .module)
        case .red: Color("Red", bundle: .module)
        }
    }
}
