import Foundation

@main
struct SMSParserTests {
    static func main() throws {
        let plain = [
            "Welkom! cadeau: 1000 MB voor je prepaid simkaart.",
            "Je simkaart is geactiveerd. Veel plezier!",
            "Café, €5 tegoed en een cadeau 🐼",
            "004100",
            "0041ZZZZ0042",
            ""
        ]
        for body in plain {
            precondition(message(body).content == body, "Plain or incomplete text must remain complete")
        }
        for text in ["Welcome", "中文", "Café €5 🐼", "Line one\nLine two\tend"] {
            let encoded = SMSParser.encodeUCS2Hex(text)
            precondition(message(encoded).content == text, "Complete UTF-16BE text must decode")
            precondition(message(encoded.lowercased()).content == text, "Lowercase hex is accepted")
        }
        precondition(message("D800").content == "D800", "Broken UTF-16 must not produce replacement text")
        let parsed = try CellularLine.decode(["iccid": "890000000000000001", "number": "+12025550101", "source": "manual"])
        precondition(parsed?.number == "+12025550101" && parsed?.simLabel == "SIM ····0001")
        let unknown = try CellularLine.decode(nil)
        precondition(unknown == nil)
        let missingNumber = try CellularLine.decode(["iccid": "890000000000000002", "number": NSNull(), "source": "unavailable"])
        precondition(missingNumber?.label == "SIM ····0002 · Number not set")
        do { _ = try CellularLine.decode(["iccid": "wrong", "number": "+123", "source": "manual"]); preconditionFailure("Bad line accepted") }
        catch LineError.invalid {}
        let noSIM = try CellularLine.current(["sim_states": "sim undetected"])
        precondition(noSIM == nil)
        print("SMSParserTests: whole-message decoding, Unicode, line identity, unknown numbers and malformed input passed")
    }

    private static func message(_ body: String) -> SMSMessage {
        let rows: [[String: Any]] = [[
            "id": 1, "number": "PROVIDER", "content": body,
            "date": "26,10,22,12,00,00,+8", "tag": "0", "mem_store": "nv"
        ]]
        let messages = try! SMSParser.parseMessages(["messages": rows])
        precondition(messages.count == 1)
        return messages[0]
    }
}
