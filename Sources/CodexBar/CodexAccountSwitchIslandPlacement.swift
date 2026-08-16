import CoreGraphics

/// Where the switch island is drawn, so it never fights a notch utility for the same pixels.
///
/// Apps that live in the notch (Perch, and others in that category) pin a fixed, transparent canvas under the
/// cutout that is far larger than what they paint at rest — Perch's is 704×670pt at `.statusBar + 2`, i.e. above
/// CodexBar's overlay. Anything CodexBar draws in that band is either hidden behind their panel or reads as part
/// of it, so the island stays out of the reserved centre entirely: beside it when there is room, below it when
/// the display is too narrow.
struct CodexAccountSwitchIslandPlacement: Equatable {
    enum Anchor: Equatable {
        /// Under the menu bar, right of the reserved centre band.
        case topTrailing
        /// Bottom of the screen, for displays too narrow to clear the band.
        case bottomCenter
    }

    /// Width reserved for notch utilities, centred on the cutout. Sized from the largest canvas observed in that
    /// category rather than from any single app's current layout.
    static let reservedCenterWidth: CGFloat = 704
    /// How wide the island is allowed to get when there is room for it.
    static let preferredMaxWidth: CGFloat = 460
    /// Below this the account name truncates to nothing useful, so the island moves out of the strip instead.
    static let minTrailingWidth: CGFloat = 260
    static let screenMargin: CGFloat = 18

    let anchor: Anchor
    let maxWidth: CGFloat

    static func resolve(
        screenWidth: CGFloat,
        reservedCenterWidth: CGFloat = Self.reservedCenterWidth,
        margin: CGFloat = Self.screenMargin) -> Self
    {
        let sideRoom = (screenWidth - reservedCenterWidth) / 2 - margin
        guard sideRoom >= Self.minTrailingWidth else {
            return Self(anchor: .bottomCenter, maxWidth: Self.preferredMaxWidth)
        }
        return Self(anchor: .topTrailing, maxWidth: min(Self.preferredMaxWidth, sideRoom))
    }
}
