import SwiftUI
import UIKit

/// A stable, distinguishable avatar per sender: service short codes and named senders read
/// differently from personal numbers, and the hue follows the number so a thread is recognisable.
struct ContactAvatar: View {
    let number: String
    var name: String? = nil
    var size: CGFloat = 44

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [hue.opacity(0.75), hue], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay { glyph.foregroundStyle(.white) }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var glyph: some View {
        let letters = number.filter(\.isLetter)
        if let first = name?.first {
            Text(String(first).uppercased())
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
        } else if !letters.isEmpty {
            Text(String(letters.prefix(2)).uppercased())
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
        } else if number.filter(\.isNumber).count <= 6 {
            Image(systemName: "building.2.fill").font(.system(size: size * 0.4))
        } else {
            Image(systemName: "person.fill").font(.system(size: size * 0.46))
        }
    }

    private var hue: Color {
        let palette: [Color] = [.blue, .teal, .indigo, .orange, .pink, .green, .purple, .cyan]
        let sum = number.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[sum % palette.count]
    }
}

/// A detected one-time code, copied with one tap.
struct CodeChip: View {
    let code: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = code
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").imageScale(.small)
                Text(copied ? "Copied" : code).monospacedDigit()
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.tint.opacity(0.12), in: .capsule)
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
        .accessibilityLabel(copied ? "Code copied" : "Copy code \(code.map(String.init).joined(separator: " "))")
    }
}

extension SMSConversation {
    /// The service brand from the newest signed incoming message, as in 【京东】.
    var brand: String? {
        messages.last { $0.tag.isIncoming && SMSParser.senderBrand(in: $0.content) != nil }
            .flatMap { SMSParser.senderBrand(in: $0.content) }
    }
    var displayName: String { brand ?? number }
    /// The latest text without the brand signature the title already shows.
    var preview: String {
        // One flowing line: line breaks in the message would leave blank preview rows.
        var text = latestMessage.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if let brand {
            for signature in ["【\(brand)】", "[\(brand)]"] {
                if text.hasPrefix(signature) { text = String(text.dropFirst(signature.count)) }
                else if text.hasSuffix(signature) { text = String(text.dropLast(signature.count)) }
            }
        }
        return text
    }
}
