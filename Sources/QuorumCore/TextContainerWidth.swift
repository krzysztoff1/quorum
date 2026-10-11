import Foundation

public enum TextContainerWidth {
    public static let tolerance = 0.5

    public static func mustMatch(containerWidth: Double, frameWidth: Double) -> Bool {
        frameWidth > 0 && abs(containerWidth - frameWidth) > tolerance
    }
}
