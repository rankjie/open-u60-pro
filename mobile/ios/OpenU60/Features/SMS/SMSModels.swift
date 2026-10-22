import Foundation

// MARK: - Tag Enum

enum SMSTag: Int, Codable, Sendable {
    case read = 0
    case unread = 1
    case sent = 2
    case failed = 3
    case draft = 4

    var isIncoming: Bool { self == .read || self == .unread }
}

// MARK: - SMS Message

struct SMSMessage: Identifiable, Codable, Equatable, Sendable {
    let id: Int
    let number: String
    let content: String
    let date: Date
    let tag: SMSTag
    let groupId: String
    let memStore: String
    var line: CellularLine? = nil
    var lineLabel: String { line?.label ?? "Line unknown" }
}

// MARK: - SMS Conversation

struct SMSConversation: Identifiable, Equatable, Sendable {
    var id: String { normalizedNumber }
    let normalizedNumber: String
    let number: String
    var messages: [SMSMessage]
    var unreadCount: Int
    var latestMessage: String
    var latestTime: Date
}

// MARK: - SMS Capacity

struct SMSCapacity: Codable, Equatable, Sendable {
    let nvTotal: Int
    let nvUsed: Int
    let simTotal: Int
    let simUsed: Int
    let unreadCount: Int

    static let empty = SMSCapacity(nvTotal: 0, nvUsed: 0, simTotal: 0, simUsed: 0, unreadCount: 0)
}

// MARK: - Parser

enum SMSParser {

    // MARK: Shared immutable helpers

    /// Hoisted out of the per-message path: constructing a `Calendar` costs more than the
    /// date arithmetic it performs, and `parseMessages` runs it up to 500 times per refresh.
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private static let gregorianCalendar = Calendar(identifier: .gregorian)

    /// GSM 7-bit default alphabet. Anything outside it forces UCS-2 on send.
    private static let gsm7Alphabet = CharacterSet(charactersIn:
        "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ ÆæßÉ" +
        " !\"#¤%&'()*+,-./0123456789:;<=>?" +
        "¡ABCDEFGHIJKLMNOPQRSTUVWXYZ" +
        "ÄÖÑÜabcdefghijklmnopqrstuvwxyz" +
        "äöñüà§")

    private static let hexDigits: [Character] = Array("0123456789ABCDEF")

    // MARK: UCS-2

    /// Decode UCS-2 hex string (UTF-16BE, 4 hex chars per code unit) to readable text.
    ///
    /// Accept only a complete, well-formed UTF-16BE value. Firmware variants can
    /// also return plain GSM text; decoding individual valid quads corrupts it.
    static func decodeUCS2Hex(_ hex: String) -> String? {
        guard hex.utf8.count.isMultiple(of: 4) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.utf8.count / 2)

        var unit: UInt16 = 0
        var digitsInQuad = 0
        for byte in hex.utf8 {
            guard let digit = hexDigit(byte) else { return nil }
            unit = (unit << 4) | digit
            digitsInQuad += 1
            if digitsInQuad == 4 {
                bytes.append(UInt8(unit >> 8))
                bytes.append(UInt8(truncatingIfNeeded: unit))
                unit = 0
                digitsInQuad = 0
            }
        }

        return String(bytes: bytes, encoding: .utf16BigEndian)
    }

    private static func hexDigit(_ byte: UInt8) -> UInt16? {
        switch byte {
        case 0x30...0x39: return UInt16(byte - 0x30)        // 0-9
        case 0x41...0x46: return UInt16(byte - 0x41) + 10   // A-F
        case 0x61...0x66: return UInt16(byte - 0x61) + 10   // a-f
        default: return nil
        }
    }

    /// Encode text to UCS-2 hex string (UTF-16BE).
    static func encodeUCS2Hex(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf16.count * 4)
        for unit in text.utf16 {
            result.append(hexDigits[Int((unit >> 12) & 0xF)])
            result.append(hexDigits[Int((unit >> 8) & 0xF)])
            result.append(hexDigits[Int((unit >> 4) & 0xF)])
            result.append(hexDigits[Int(unit & 0xF)])
        }
        return result
    }

    // MARK: Dates

    /// Parse ZTE date format "YY,MM,DD,HH,MM,SS,TZ" to Date.
    static func parseSMSDate(_ dateStr: String) -> Date {
        let parts = dateStr.split(separator: ",")
        guard parts.count >= 6 else { return Date() }

        var components = DateComponents()
        components.year = (Int(parts[0]) ?? 0) + 2000
        components.month = Int(parts[1]) ?? 1
        components.day = Int(parts[2]) ?? 1
        components.hour = Int(parts[3]) ?? 0
        components.minute = Int(parts[4]) ?? 0
        components.second = Int(parts[5]) ?? 0

        // Parse timezone offset if present (e.g. "+0", "+32" = +8h in quarter-hours)
        if parts.count >= 7,
           let quarters = Int(parts[6].trimmingCharacters(in: .whitespaces)) {
            components.timeZone = TimeZone(secondsFromGMT: quarters * 15 * 60)
        }

        return utcCalendar.date(from: components) ?? Date()
    }

    static func validatedDate(_ text: String) throws -> Date {
        let fields = text.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 7, let year = Int(fields[0]), (0...99).contains(year),
              let month = Int(fields[1]), (1...12).contains(month),
              let day = Int(fields[2]), (1...31).contains(day),
              let hour = Int(fields[3]), (0...23).contains(hour),
              let minute = Int(fields[4]), (0...59).contains(minute),
              let second = Int(fields[5]), (0...59).contains(second),
              let zone = Int(fields[6]), (-48...56).contains(zone) else { throw SMSDeliveryError.invalid }
        let date = parseSMSDate(text)
        var calendar = utcCalendar
        calendar.timeZone = TimeZone(secondsFromGMT: zone * 900)!
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard actual.year == year + 2000, actual.month == month, actual.day == day,
              actual.hour == hour, actual.minute == minute, actual.second == second else { throw SMSDeliveryError.invalid }
        return date
    }

    /// Format current time in ZTE SMS send format (semicolons, tz in hours).
    /// JS: "YY;MM;DD;HH;MM;SS;+TZ" where TZ is offset in hours.
    static func formatSMSTime() -> String {
        let now = Date()
        let tz = TimeZone.current
        let comps = gregorianCalendar.dateComponents(in: tz, from: now)

        let year = (comps.year ?? 2026) % 100
        let offsetHours = tz.secondsFromGMT() / 3600
        let tzStr = offsetHours >= 0 ? "+\(offsetHours)" : "\(offsetHours)"

        return String(format: "%02d;%02d;%02d;%02d;%02d;%02d;%@",
                      year, comps.month ?? 1, comps.day ?? 1,
                      comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0, tzStr)
    }

    // MARK: Senders

    /// Determine encode type for sending.
    static func getEncodeType(_ text: String) -> String {
        if text.unicodeScalars.allSatisfy({ gsm7Alphabet.contains($0) }) {
            return "GSM7_default"
        }
        return "UNICODE"
    }

    /// Normalize a sender into a conversation key.
    ///
    /// Numeric senders collapse to their last 8 digits so that "+1 555 010 1234",
    /// "5550101234" and "005550101234" share one thread. Alphanumeric sender IDs
    /// ("AMAZON", "VM-HDFCBK") contain no meaningful digits, so they keep their own
    /// case-folded identity — stripping to digits would merge every bank, carrier and
    /// marketing sender into a single empty-keyed conversation.
    static func normalizeNumber(_ number: String) -> String {
        let trimmed = number.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(where: \.isLetter) {
            return trimmed.uppercased()
        }

        let digits = trimmed.filter(\.isNumber)
        guard !digits.isEmpty else { return trimmed }
        return digits.count > 8 ? String(digits.suffix(8)) : digits
    }

    /// Group messages into conversations by normalized sender.
    static func groupIntoConversations(_ messages: [SMSMessage]) -> [SMSConversation] {
        var grouped: [String: [SMSMessage]] = [:]
        grouped.reserveCapacity(messages.count)

        for msg in messages {
            let key = normalizeNumber(msg.number)
            grouped[key, default: []].append(msg)
        }

        return grouped.map { key, msgs in
            let sorted = msgs.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
            let latest = sorted.last!
            let unread = msgs.reduce(into: 0) { count, msg in
                if msg.tag == .unread { count += 1 }
            }
            // Use the longest number variant as display number
            let displayNumber = msgs.max(by: { $0.number.count < $1.number.count })?.number ?? latest.number

            return SMSConversation(
                normalizedNumber: key,
                number: displayNumber,
                messages: sorted,
                unreadCount: unread,
                latestMessage: latest.content,
                latestTime: latest.date
            )
        }.sorted { $0.latestTime > $1.latestTime }
    }

    /// Parse raw SMS data from the agent into SMSMessage array.
    /// Response format: { "messages": [ { "id":Int, "number":String, "content":String(UCS2hex),
    ///   "date":"YY,MM,DD,HH,MM,SS,TZ", "tag":"0".."4", "draft_group_id":String, "mem_store":String } ] }
    static func parseMessages(_ data: [String: Any]) throws -> [SMSMessage] {
        guard let list = data["messages"] as? [[String: Any]] else { throw SMSDeliveryError.invalid }

        return try list.map { item -> SMSMessage in
            guard let id = item["id"] as? Int,
                  let number = item["number"] as? String,
                  let body = item["content"] as? String,
                  let dateStr = item["date"] as? String,
                  let tagStr = item["tag"] as? String,
                  let tagInt = Int(tagStr),
                  let tag = SMSTag(rawValue: tagInt) else { throw SMSDeliveryError.invalid }

            let content = decodeUCS2Hex(body) ?? body

            return SMSMessage(
                id: id,
                number: number,
                content: content,
                date: try validatedDate(dateStr),
                tag: tag,
                groupId: item["draft_group_id"] as? String ?? "",
                memStore: item["mem_store"] as? String ?? "nv",
                line: try CellularLine.decode(item["line"])
            )
        }
    }

    /// Parse capacity response.
    static func parseCapacity(_ data: [String: Any]) -> SMSCapacity {
        SMSCapacity(
            nvTotal: data["sms_nv_total"] as? Int ?? 0,
            nvUsed: data["sms_nvused_total"] as? Int ?? 0,
            simTotal: data["sms_sim_total"] as? Int ?? 0,
            simUsed: data["sms_simused_total"] as? Int ?? 0,
            unreadCount: data["sms_dev_unread_num"] as? Int ?? 0
        )
    }
}

// MARK: - Verification codes

extension SMSParser {
    private static let codeKeywords = ["验证码", "校验码", "动态码", "动态密码", "确认码", "验证代码",
                                       "verification", "passcode", "code", "otp"]

    /// The one-time code a message carries: a 4–8 digit run standing on its own, closest to a
    /// code keyword and within 40 characters of it. Amounts, dates and order numbers that are
    /// not near a keyword are not codes.
    static func verificationCode(in text: String) -> String? {
        let characters = Array(text)
        let lower = Array(text.lowercased())
        guard characters.count == lower.count else { return nil }
        var keywords: [Range<Int>] = []
        for keyword in codeKeywords {
            let pattern = Array(keyword)
            guard pattern.count <= lower.count else { continue }
            for start in 0...(lower.count - pattern.count) where Array(lower[start..<start + pattern.count]) == pattern {
                keywords.append(start..<start + pattern.count)
            }
        }
        guard !keywords.isEmpty else { return nil }
        var best: (code: String, distance: Int)?
        var index = 0
        while index < characters.count {
            guard characters[index].isASCII, characters[index].isNumber else { index += 1; continue }
            var end = index
            while end < characters.count, characters[end].isASCII, characters[end].isNumber { end += 1 }
            // A run glued to letters (an ID such as AB1234) or part of a decimal is not a code.
            func letter(_ position: Int) -> Bool {
                characters.indices.contains(position) && characters[position].isASCII && characters[position].isLetter
            }
            func separator(_ position: Int, digitAt neighbour: Int) -> Bool {
                characters.indices.contains(position) && characters.indices.contains(neighbour)
                    && [".", ","].contains(characters[position]) && characters[neighbour].isNumber
            }
            let embedded = letter(index - 1) || letter(end)
                || separator(index - 1, digitAt: index - 2) || separator(end, digitAt: end + 1)
            if (4...8).contains(end - index), !embedded {
                let distance = keywords.map { $0.upperBound <= index ? index - $0.upperBound : max(0, $0.lowerBound - end) }.min()!
                if distance <= 40, best.map({ distance < $0.distance }) ?? true {
                    best = (String(characters[index..<end]), distance)
                }
            }
            index = end
        }
        return best?.code
    }
}

// MARK: - Sender brand

extension SMSParser {
    /// The signature service senders put at the start or end of a message, as in 【京东】 or [Alipay].
    static func senderBrand(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("【", "】"), ("[", "]")] {
            if trimmed.hasPrefix(open), let end = trimmed.range(of: close) {
                return brand(String(trimmed[trimmed.index(after: trimmed.startIndex)..<end.lowerBound]))
            }
            if trimmed.hasSuffix(close), let start = trimmed.range(of: open, options: .backwards) {
                return brand(String(trimmed[start.upperBound..<trimmed.index(before: trimmed.endIndex)]))
            }
        }
        return nil
    }

    private static func brand(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespaces)
        return (1...12).contains(name.count) ? name : nil
    }
}
