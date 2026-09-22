import Foundation

/// Format assertions used by the `format` keyword. Unknown formats are accepted silently.
enum SchemaFormats {
    /// Returns a human-readable failure message when `value` does not satisfy `format`, or nil
    /// when it does (or when the format is unknown).
    static func failureMessage(format: String, value: String) -> String? {
        switch format {
        case "date-time": return isDateTime(value) ? nil : "Not a valid date-time"
        case "date": return isDate(value) ? nil : "Not a valid date"
        case "time": return isTime(value) ? nil : "Not a valid time"
        case "email": return isEmail(value) ? nil : "Not a valid email address"
        case "uri": return isURI(value, requireScheme: true) ? nil : "Not a valid URI"
        case "uri-reference": return isURI(value, requireScheme: false) ? nil : "Not a valid URI reference"
        case "uuid": return isUUID(value) ? nil : "Not a valid UUID"
        case "ipv4": return isIPv4(value) ? nil : "Not a valid IPv4 address"
        case "ipv6": return isIPv6(value) ? nil : "Not a valid IPv6 address"
        case "hostname": return isHostname(value) ? nil : "Not a valid hostname"
        case "regex": return isRegex(value) ? nil : "Not a valid regular expression"
        default: return nil
        }
    }

    // MARK: Regex helpers

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns below are literals; a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern)
    }

    /// Returns the capture groups of the first full match, or nil when the pattern does not match.
    private static func captures(_ regex: NSRegularExpression, in string: String) -> [String]? {
        let ns = string as NSString
        guard let match = regex.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<match.numberOfRanges).map { i in
            let range = match.range(at: i)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
    }

    private static let dateRegex = regex(#"^(\d{4})-(\d{2})-(\d{2})$"#)
    private static let timeRegex = regex(#"^(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:[Zz]|([+-])(\d{2}):(\d{2}))$"#)
    private static let dateTimeRegex = regex(#"^(\d{4}-\d{2}-\d{2})[Tt](.+)$"#)
    private static let emailRegex = regex(#"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"#)
    private static let uuidRegex = regex(#"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#)
    private static let schemeRegex = regex(#"^[A-Za-z][A-Za-z0-9+.-]*:"#)
    private static let hostLabelRegex = regex(#"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$"#)
    private static let percentRegex = regex(#"%(?![0-9A-Fa-f]{2})"#)

    // MARK: Dates and times

    private static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    static func isDate(_ value: String) -> Bool {
        guard let parts = captures(dateRegex, in: value), let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return false
        }
        guard (1...12).contains(month), day >= 1 else { return false }
        let lengths = [31, isLeapYear(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= lengths[month - 1]
    }

    static func isTime(_ value: String) -> Bool {
        guard let parts = captures(timeRegex, in: value), let hour = Int(parts[0]), let minute = Int(parts[1]), let second = Int(parts[2]) else {
            return false
        }
        guard hour <= 23, minute <= 59, second <= 60 else { return false }
        if !parts[3].isEmpty {
            guard let offsetHour = Int(parts[4]), let offsetMinute = Int(parts[5]), offsetHour <= 23, offsetMinute <= 59 else { return false }
        }
        return true
    }

    static func isDateTime(_ value: String) -> Bool {
        guard let parts = captures(dateTimeRegex, in: value) else { return false }
        return isDate(parts[0]) && isTime(parts[1])
    }

    // MARK: Identifiers and addresses

    static func isEmail(_ value: String) -> Bool {
        guard value.count <= 254, !value.contains(".."), !value.hasPrefix(".") else { return false }
        guard let at = value.firstIndex(of: "@"), value[..<at].last != "." else { return false }
        return captures(emailRegex, in: value) != nil
    }

    static func isUUID(_ value: String) -> Bool {
        captures(uuidRegex, in: value) != nil
    }

    private static let uriCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")

    static func isURI(_ value: String, requireScheme: Bool) -> Bool {
        guard value.unicodeScalars.allSatisfy(uriCharacters.contains) else { return false }
        guard value.filter({ $0 == "#" }).count <= 1 else { return false }
        guard captures(percentRegex, in: value) == nil else { return false }
        if requireScheme {
            return captures(schemeRegex, in: value) != nil
        }
        return true
    }

    static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            if part.count > 1, part.first == "0" { return false }
            guard let octet = Int(part), octet <= 255 else { return false }
        }
        return true
    }

    static func isIPv6(_ value: String) -> Bool {
        guard !value.isEmpty, value.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return false }
        let halves = value.components(separatedBy: "::")
        guard halves.count <= 2 else { return false }
        func groups(_ part: String) -> [String] { part.isEmpty ? [] : part.components(separatedBy: ":") }
        let all = groups(halves[0]) + (halves.count == 2 ? groups(halves[1]) : [])
        var count = 0
        for (i, group) in all.enumerated() {
            if group.contains(".") {
                guard i == all.count - 1, isIPv4(group) else { return false }
                count += 2
            } else {
                guard (1...4).contains(group.count), group.allSatisfy(\.isHexDigit) else { return false }
                count += 1
            }
        }
        return halves.count == 2 ? count <= 7 : count == 8
    }

    static func isHostname(_ value: String) -> Bool {
        var host = value
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.count <= 253 else { return false }
        return host.components(separatedBy: ".").allSatisfy { captures(hostLabelRegex, in: $0) != nil }
    }

    static func isRegex(_ value: String) -> Bool {
        (try? NSRegularExpression(pattern: value)) != nil
    }
}
