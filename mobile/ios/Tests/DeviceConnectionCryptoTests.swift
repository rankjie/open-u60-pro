import CryptoKit
import Foundation
#if os(macOS)
import Vision
#endif

@main struct DeviceConnectionCryptoTests {
    static func main() throws {
        let router = UUID(uuidString:"00000000-0000-4000-8000-000000000001")!
        let request = UUID(uuidString:"00000000-0000-4000-8000-000000000002")!
        let qr = "{\"type\":\"openu60-connect\",\"version\":1,\"device\":\"U60-\(router.uuidString)\",\"server\":\"https://synthetic.invalid:8443/openu60\"}"
        let scanned = try DeviceConnectionQRCode(qr)
        precondition(scanned.code == "U60-\(router.uuidString.lowercased())" && scanned.server.absoluteString == "https://synthetic.invalid:8443/openu60")
        for invalid in [qr.replacingOccurrences(of:"\"version\":1",with:"\"version\":2"),
                        qr.replacingOccurrences(of:"openu60-connect",with:"unrelated"),
                        qr.replacingOccurrences(of:"https://",with:"http://"),
                        qr.replacingOccurrences(of:"https://",with:"https://user:password@"),
                        qr.replacingOccurrences(of:"openu60\"",with:"openu60?token=value\""),
                        qr.replacingOccurrences(of:router.uuidString,with:"not-a-device"), "LPA:1$synthetic.invalid$code", String(repeating:"x",count:4097)] {
            do { _ = try DeviceConnectionQRCode(invalid); preconditionFailure("Invalid connection QR accepted") } catch {}
        }
#if os(macOS)
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--qr-image" {
            let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
            try VNImageRequestHandler(url:URL(fileURLWithPath:CommandLine.arguments[2])).perform([request])
            let values = request.results?.compactMap(\.payloadStringValue) ?? []
            precondition(values.count == 1, "The rendered native page must contain one readable QR")
            let decoded = try DeviceConnectionQRCode(values[0])
            precondition(decoded.code == scanned.code && decoded.server.absoluteString == "https://synthetic.invalid/openu60")
            print("Native QR image: Apple Vision decoded the complete device and server for the App")
            return
        }
#endif
        for code in [router.uuidString, "U60-\(router.uuidString)", " u60-\(router.uuidString.lowercased())\n"] {
            let parsed = try DeviceConnectionCode(code)
            precondition(parsed.routerID == router)
        }
        for code in ["", "U60-hello", "U60-00000000-0000-0000-0000-000000000000"] {
            do { _ = try DeviceConnectionCode(code); preconditionFailure("Invalid connection string accepted") } catch {}
        }
        // Fixed, public test material. Never used by the app's credential source.
        let raw = Data(repeating:1, count:32)
        let key = try P256.KeyAgreement.PrivateKey(rawRepresentation:raw)
        let password = "synthetic-device-password", token = String(repeating:"x", count:43)
        let publicKey = key.publicKey.x963Representation
        var value = try DeviceConnectionCode.seal(password:password, publicKey:publicKey, routerID:router,
            requestID:request, phoneToken:token, serverTime:1_800_000_000)
        let enc = Data(base64Encoded:value["enc"] as! String)!, ciphertext = Data(base64Encoded:value["ciphertext"] as! String)!
        let aad = Data("OpenU60 connect v1\n\(router.uuidString.lowercased())\n\(request.uuidString.lowercased())\n\(token)".utf8)
        var recipient = try HPKE.Recipient(privateKey:key, ciphersuite:.P256_SHA256_AES_GCM_256,
            info:Data("OpenU60 device connect v1".utf8), encapsulatedKey:enc)
        let opened = try recipient.open(ciphertext, authenticating:aad)
        let payload = try JSONSerialization.jsonObject(with:opened) as! [String:Any]
        precondition(payload["password"] as? String == password && payload["expiresAt"] as? Int == 1_800_000_060)
        var altered = try HPKE.Recipient(privateKey:key, ciphersuite:.P256_SHA256_AES_GCM_256,
            info:Data("OpenU60 device connect v1".utf8), encapsulatedKey:enc)
        do { _ = try altered.open(ciphertext, authenticating:Data("another device".utf8)); preconditionFailure("Altered context accepted") }
        catch {}
        if CommandLine.arguments.count == 2 {
            value["syntheticPrivateKey"] = raw.base64EncodedString()
            value["syntheticPassword"] = password
            value["serverTime"] = 1_800_000_000
            try JSONSerialization.data(withJSONObject:value, options:[.prettyPrinted,.sortedKeys])
                .write(to:URL(fileURLWithPath:CommandLine.arguments[1]), options:.atomic)
        }
        print("Device connection: string validation, HPKE sealing and context authentication passed")
    }
}
