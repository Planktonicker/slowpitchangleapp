// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI
import UIKit

/// SwingLab's visual identity: optic yellow on black, loud and readable in
/// direct sunlight — the app lives on a tripod outdoors.
///
/// The app is always dark. That is a deliberate commitment, not a missing
/// light mode: the capture screen is a viewfinder, and the rest of the app
/// should read like the same piece of equipment.
enum Theme {

    // MARK: - Palette

    /// Optic yellow — the ball's own colour.
    static let yellow = Color(red: 1.00, green: 0.85, blue: 0.05)
    static let yellowUI = UIColor(red: 1.00, green: 0.85, blue: 0.05, alpha: 1)
    /// True black ground.
    static let black = Color(red: 0.04, green: 0.04, blue: 0.045)
    static let blackUI = UIColor(red: 0.04, green: 0.04, blue: 0.045, alpha: 1)
    /// Raised card surface.
    static let surface = Color(red: 0.10, green: 0.10, blue: 0.11)
    /// Secondary text on black.
    static let steel = Color(red: 0.62, green: 0.64, blue: 0.66)

    // Semantic — reserved for pass/fail meaning, never decoration.
    static let pass = Color(red: 0.25, green: 0.82, blue: 0.48)
    static let fail = Color(red: 0.95, green: 0.30, blue: 0.29)
    static let warn = Color(red: 0.98, green: 0.63, blue: 0.15)

    // MARK: - Type

    /// Big scoreboard numerals.
    static func numeral(_ size: CGFloat) -> Font {
        .system(size: size, weight: .black, design: .rounded)
    }

    /// Shouty section labels.
    static func label(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .heavy, design: .rounded)
    }

    // MARK: - Global appearance

    /// Paint UIKit-backed chrome (tab bar, nav bar) to match. Call once at
    /// app start.
    static func installAppearance() {
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = blackUI
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            item.selected.iconColor = yellowUI
            item.selected.titleTextAttributes = [.foregroundColor: yellowUI]
            item.normal.iconColor = UIColor(white: 0.55, alpha: 1)
            item.normal.titleTextAttributes = [.foregroundColor: UIColor(white: 0.55, alpha: 1)]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = blackUI
        nav.titleTextAttributes = [.foregroundColor: UIColor.white,
                                   .font: UIFont.systemFont(ofSize: 17, weight: .heavy)]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white,
                                        .font: UIFont.systemFont(ofSize: 32, weight: .black)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
    }
}

/// Bounds on the transient banner.
///
/// It reserves real layout space as a top safe-area inset (see `RootView`), so
/// its height is measured rather than guessed — but it still must not be free
/// to grow without limit, or a long error message would push the whole capture
/// HUD down the screen.
enum BannerMetrics {
    static let maxLines = 3
}

// MARK: - Button styles

/// The big commitment button: yellow slab, black text.
///
/// Both styles read `isEnabled`. Without it a `.disabled()` button looked
/// exactly like an enabled one — pressing it did nothing and gave no reason,
/// which reads as a broken app rather than a blocked action.
struct SlabButtonStyle: ButtonStyle {
    var fill: Color = Theme.yellow
    var textColor: Color = .black
    var size: CGFloat = 17
    var verticalPadding: CGFloat = 16
    /// Pin the slab to one height so a row of controls lines up, instead of
    /// each sizing itself from its own padding.
    ///
    /// `minHeight`, deliberately not `maxHeight: .infinity`. Infinity does not
    /// mean "fill the frame my caller gave me" — it means "take every point of
    /// vertical space available", and in a portrait VStack that is the entire
    /// screen. That is exactly how the MANUAL button became a full-height bar.
    var minHeight: CGFloat?
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .black, design: .rounded))
            .textCase(.uppercase)
            .tracking(1.2)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(isEnabled ? fill : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(isEnabled ? textColor : Theme.steel)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

/// Secondary action: black slab, yellow outline.
struct OutlineButtonStyle: ButtonStyle {
    var verticalPadding: CGFloat = 12
    var cornerRadius: CGFloat = 12
    /// See `SlabButtonStyle.minHeight`.
    var minHeight: CGFloat?
    /// Tappable height, for when the pill must LOOK smaller than the 44pt
    /// minimum touch target.
    ///
    /// Applied inside `makeBody`, which is the button's own body. A
    /// `.frame`/`.contentShape` pair stacked AFTER `.buttonStyle` wraps the
    /// Button from outside, so the touch lands on the wrapper and the pill
    /// stays as small a target as it looks.
    var hitHeight: CGFloat?
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .textCase(.uppercase)
            .tracking(0.8)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Theme.yellow.opacity(isEnabled ? 0.85 : 0.3), lineWidth: 1.5))
            .foregroundStyle(isEnabled ? Theme.yellow : Theme.steel)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .frame(height: hitHeight)
            .contentShape(Rectangle())
    }
}

/// Status chip with a hard edge.
struct StatChip: View {
    var text: String
    var color: Color
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .textCase(.uppercase)
            .tracking(0.6)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(filled ? color : color.opacity(0.18), in: Capsule())
            .foregroundStyle(filled ? Color.black : color)
    }
}
