import Foundation

/// Minimal RFC 4180 CSV reader (quoted fields, embedded commas/quotes/newlines, BOM, CRLF).
public enum CSV {
    public static func parse(_ text: String) -> (columns: [String], rows: [[String: String]]) {
        var records: [[String]] = [], field = "", record: [String] = []
        var inQuotes = false
        var chars = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                record.append(field); field = ""
            } else if c == "\n" || c == "\r" || c == "\r\n" {
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                record.append(field); field = ""
                if !(record.count == 1 && record[0].isEmpty) { records.append(record) }
                record = []
            } else { field.append(c) }
            i += 1
        }
        guard let header = records.first else { return ([], []) }
        let rows = records.dropFirst().map { r in
            Dictionary(header.enumerated().map { ($1, $0 < r.count ? r[$0] : "") }, uniquingKeysWith: { a, _ in a })
        }
        return (header, rows)
    }
}
