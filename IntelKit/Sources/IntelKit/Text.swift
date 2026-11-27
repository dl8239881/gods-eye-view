import Foundation

extension String {
    /// Case- and diacritic-insensitive form used by name search and stable ids.
    func intelFolded() -> String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }
}

enum HeaderKey {
    /// `source_url`, `sourceURL`, and `Source URL` all become `sourceurl`.
    static func normalize(_ name: String) -> String {
        name.intelFolded().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }.reduce(into: "") { partial, scalar in
            partial.unicodeScalars.append(scalar)
        }
    }
}

enum LikePattern {
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

enum StableID {
    static func fnv64(_ string: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    static func entity(kind: EntityKind, name: String, externalID: String?) -> String {
        if let externalID {
            let trimmed = externalID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return "\(kind.rawValue):\(fnv64(trimmed))"
            }
        }
        return "\(kind.rawValue):\(fnv64(kind.rawValue + "\n" + name.intelFolded()))"
    }

    static func link(type: String, fromID: String, toID: String) -> String {
        "link:\(fnv64(type + "\n" + fromID + "\n" + toID))"
    }

    static func gdeltArticle(_ url: String) -> String {
        "gdelt:event:\(fnv64(url.trimmingCharacters(in: .whitespacesAndNewlines)))"
    }

    static func gdeltActor(domain: String) -> String {
        "gdelt:actor:\(domain.intelFolded())"
    }

    static func gdeltPlace(name: String) -> String {
        "gdelt:place:\(fnv64(name.intelFolded()))"
    }

    static func gdeltLink(from: String, type: String, to: String) -> String {
        "gdelt:link:\(fnv64(from + "\n" + type + "\n" + to))"
    }

    static func gdeltQueryHub(_ query: String) -> String {
        "gdelt:query:\(fnv64(query.intelFolded()))"
    }
}

enum IntelDate {
    static func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return nil
        }
        if let gdelt = parseGDELT(text) {
            return gdelt
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withFullDate]
        if let date = formatter.date(from: text) {
            return date
        }
        return nil
    }

    /// `YYYYMMDDHHMMSS` in UTC, the form GDELT expects for `startdatetime`.
    static func gdeltTimestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return String(
            format: "%04d%02d%02d%02d%02d%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// GDELT seen dates look like `20241115T153000Z` or `20241115153000`.
    private static func parseGDELT(_ text: String) -> Date? {
        let head = text.prefix(8)
        guard head.count == 8, head.allSatisfy(\.isNumber) else {
            return nil
        }
        let digits = text.filter(\.isNumber)
        guard digits.count >= 14 else {
            return nil
        }
        let stamp = String(digits.prefix(14))
        func take(_ offset: Int) -> Int? {
            let start = stamp.index(stamp.startIndex, offsetBy: offset)
            let end = stamp.index(start, offsetBy: offset == 0 ? 4 : 2)
            return Int(stamp[start..<end])
        }
        guard
            let year = take(0),
            let month = take(4),
            let day = take(6),
            let hour = take(8),
            let minute = take(10),
            let second = take(12)
        else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            )
        )
    }
}

enum HTMLText {
    private static let namedEntities = [
        "&amp;": "&",
        "&lt;": "<",
        "&gt;": ">",
        "&quot;": "\"",
        "&apos;": "'",
        "&#39;": "'",
        "&nbsp;": " ",
    ]

    static func anchorArticles(in html: String) -> [(url: String, title: String)] {
        var articles: [(url: String, title: String)] = []
        var searchFrom = html.startIndex
        while searchFrom < html.endIndex {
            guard
                let open = html.range(
                    of: "<a",
                    options: .caseInsensitive,
                    range: searchFrom..<html.endIndex
                )
            else {
                break
            }
            let afterName = open.upperBound
            if afterName < html.endIndex {
                let next = html[afterName]
                if next.isLetter || next.isNumber {
                    searchFrom = afterName
                    continue
                }
            }
            guard let tagEnd = html[afterName...].firstIndex(of: ">") else {
                break
            }
            let tag = String(html[afterName..<tagEnd])
            let contentStart = html.index(after: tagEnd)
            guard
                let close = html.range(
                    of: "</a>",
                    options: .caseInsensitive,
                    range: contentStart..<html.endIndex
                )
            else {
                break
            }
            if let href = hrefValue(in: tag) {
                let decodedURL = decodeEntities(href).trimmingCharacters(in: .whitespacesAndNewlines)
                if !decodedURL.isEmpty, !decodedURL.lowercased().hasPrefix("javascript:") {
                    let title = plainText(String(html[contentStart..<close.lowerBound]))
                    articles.append((decodedURL, title.isEmpty ? decodedURL : title))
                }
            }
            searchFrom = close.upperBound
        }
        return articles
    }

    static func plainText(_ html: String) -> String {
        var stripped = ""
        var inTag = false
        for character in html {
            if character == "<" {
                inTag = true
                continue
            }
            if character == ">" {
                inTag = false
                continue
            }
            if !inTag {
                stripped.append(character)
            }
        }
        return decodeEntities(stripped)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func decodeEntities(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&",
                let semi = text[index...].firstIndex(of: ";"),
                text.distance(from: index, to: semi) <= 16
            {
                let token = String(text[index...semi])
                if let replacement = namedEntities[token.lowercased()] ?? numericEntity(token) {
                    result.append(replacement)
                    index = text.index(after: semi)
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    private static func hrefValue(in tag: String) -> String? {
        guard let href = tag.range(of: "href", options: .caseInsensitive) else {
            return nil
        }
        var index = href.upperBound
        index = skipWhitespace(tag, from: index)
        guard index < tag.endIndex, tag[index] == "=" else {
            return nil
        }
        index = tag.index(after: index)
        index = skipWhitespace(tag, from: index)
        guard index < tag.endIndex else {
            return nil
        }
        let quote = tag[index]
        if quote == "\"" || quote == "'" {
            let start = tag.index(after: index)
            guard let end = tag[start...].firstIndex(of: quote) else {
                return nil
            }
            return String(tag[start..<end])
        }
        let start = index
        while index < tag.endIndex, !tag[index].isWhitespace, tag[index] != ">" {
            index = tag.index(after: index)
        }
        return String(tag[start..<index])
    }

    private static func skipWhitespace(_ text: String, from index: String.Index) -> String.Index {
        var index = index
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        return index
    }

    private static func numericEntity(_ token: String) -> String? {
        guard token.hasPrefix("&#"), token.hasSuffix(";") else {
            return nil
        }
        let body = token.dropFirst(2).dropLast()
        let scalar: UInt32?
        if body.first == "x" || body.first == "X" {
            scalar = UInt32(body.dropFirst(), radix: 16)
        } else {
            scalar = UInt32(body, radix: 10)
        }
        guard let scalar, let unicode = UnicodeScalar(scalar) else {
            return nil
        }
        return String(Character(unicode))
    }
}
