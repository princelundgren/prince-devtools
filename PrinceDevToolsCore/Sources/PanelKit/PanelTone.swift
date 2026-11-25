import SwiftUI

/// A card's state. Each tone has its own symbol, so the state never rests on colour alone.
public enum PanelTone: Sendable {
    /// No reading yet; neutral, never green or red.
    case notKnown
    case green
    case yellow
    case red

    public var symbolName: String {
        switch self {
        case .notKnown: "circle.dashed"
        case .green: "checkmark.circle.fill"
        case .yellow: "exclamationmark.triangle.fill"
        case .red: "exclamationmark.octagon.fill"
        }
    }

    public var color: Color {
        switch self {
        case .notKnown: .secondary
        case .green: Color("Green", bundle: .module)
        case .yellow: Color("Yellow", bundle: .module)
        case .red: Color("Red", bundle: .module)
        }
    }
}
