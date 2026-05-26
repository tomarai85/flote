import CoreGraphics

enum GoldenRatio {
    static let phi: CGFloat = 1.6180339887

    // Width values intentionally match FloatingPanel.fixedContentWidth (160px)
    // so newly created notes start at the uniform size.
    static let small  = CGSize(width: 160, height: 100)
    static let medium = CGSize(width: 160, height: 120)
    static let large  = CGSize(width: 160, height: 160)
}
