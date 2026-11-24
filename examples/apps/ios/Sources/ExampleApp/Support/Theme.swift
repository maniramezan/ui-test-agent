import SwiftUI

/// The app's spacing and type tokens. Views take their metrics from here, never from literals.
enum Theme {
    enum Spacing {
        static let small: CGFloat = 8
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
    }

    enum Typography {
        static let title = Font.largeTitle.bold()
        static let body = Font.body
        static let detail = Font.subheadline
        static let caption = Font.footnote
    }

    enum Palette {
        static let failure = Color.red
        static let secondary = Color.secondary
        static let done = Color.green
    }
}
