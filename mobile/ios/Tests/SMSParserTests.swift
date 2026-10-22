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
        let codes: [(String, String?)] = [
            ("【招商银行】您的验证码为 482913，5分钟内有效。", "482913"),
            ("Your Apple ID code is: 739104. Don't share it.", "739104"),
            ("G-583920 is your Google verification code.", "583920"),
            ("动态密码 123456，请勿泄露", "123456"),
            ("您的校验码是0412", "0412"),
            ("验证码 771203，如非本人操作请致电 95555", "771203"),
            ("Your login code is 5521. Ref 99887766", "5521"),
            ("您本月已使用流量 1024MB，余额 35.20元", nil),
            ("Your order 123456789 has shipped", nil),
            ("Meeting moved to 1530 tomorrow", nil),
            ("OTP 12.5034 is not a code", nil),
            ("", nil),
        ]
        let brands: [(String, String?)] = [
            ("【京东】验证码：482913，您正在登录京东账号", "京东"),
            ("您的验证码为 1234，请勿泄露。【招商银行】", "招商银行"),
            ("[Alipay] Your code is 1234", "Alipay"),
            ("No brackets here", nil),
            ("【】空的", nil),
            ("【这是一个非常非常非常长的不是品牌的括号内容】", nil),
            ("Reply 【1】 to confirm", nil),
        ]
        for (text, expected) in brands {
            let found = SMSParser.senderBrand(in: text)
            precondition(found == expected, "brand for \(text): \(found ?? "nil")")
        }
        for (text, expected) in codes {
            let found = SMSParser.verificationCode(in: text)
            precondition(found == expected, "verification code for \(text): \(found ?? "nil")")
        }
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
