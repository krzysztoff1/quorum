import Foundation

public enum BenchmarkMetrics {

    public static func urlDomains(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s)\]>]+"#) else { return [] }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { m -> String? in
            var raw = ns.substring(with: m.range)
            while let last = raw.last, ".,;:)]>\"'".contains(last) { raw.removeLast() }
            guard let host = URL(string: raw)?.host?.lowercased() else { return nil }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
    }

    public static func simpsonDiversity(_ domains: [String]) -> Double {
        guard !domains.isEmpty else { return 0 }
        var counts: [String: Int] = [:]
        for d in domains { counts[d, default: 0] += 1 }
        let total = Double(domains.count)
        let sumSquared = counts.values.reduce(0.0) { $0 + pow(Double($1) / total, 2) }
        return 1 - sumSquared
    }

    public static func allAgree(_ winners: [String]) -> Bool {
        guard let first = winners.first, !winners.isEmpty else { return false }
        return winners.allSatisfy { $0 == first }
    }

    public static func meanPassRate(_ passArrays: [[Bool]]) -> Double {
        let nonEmpty = passArrays.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return 0 }
        let perJudge = nonEmpty.map { arr in Double(arr.filter { $0 }.count) / Double(arr.count) }
        return perJudge.reduce(0, +) / Double(perJudge.count)
    }
}
