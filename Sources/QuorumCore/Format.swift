import Foundation

public enum Format {
    public static func money(_ amount: Decimal) -> String {
        money((amount as NSDecimalNumber).doubleValue)
    }

    public static func money(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
    }

    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60, rest = total % 60
        return minutes > 0 ? "\(minutes)m \(rest)s" : "\(rest)s"
    }
}
