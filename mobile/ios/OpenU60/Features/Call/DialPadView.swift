import SwiftUI

struct DialPadView: View {
    var keySize: CGFloat = 80
    var onPlus: (() -> Void)? = nil
    var onDigit: (String) -> Void

    private static let rows: [[DialKey]] = [
        [.init("1", sub: ""), .init("2", sub: "ABC"), .init("3", sub: "DEF")],
        [.init("4", sub: "GHI"), .init("5", sub: "JKL"), .init("6", sub: "MNO")],
        [.init("7", sub: "PQRS"), .init("8", sub: "TUV"), .init("9", sub: "WXYZ")],
        [.init("*", sub: ""), .init("0", sub: "+"), .init("#", sub: "")],
    ]

    var body: some View {
        Grid(horizontalSpacing: keySize * 0.275, verticalSpacing: keySize * 0.20) {
            ForEach(Self.rows, id: \.self) { row in
                GridRow {
                    ForEach(row) { key in
                        DialKeyButton(key: key, size: keySize,
                                      onPlus: key.digit == "0" ? onPlus : nil,
                                      onDigit: onDigit)
                    }
                }
            }
        }
    }
}

private struct DialKeyButton: View {
    let key: DialKey
    let size: CGFloat
    let onPlus: (() -> Void)?
    let onDigit: (String) -> Void
    @State private var insertedPlus = false

    var body: some View {
        Button {
            if !insertedPlus { onDigit(key.digit) }
        } label: {
            Group {
                if key.digit == "*" {
                    Image(systemName: "asterisk").font(.system(size: size * 0.325, weight: .regular))
                } else if key.digit == "#" {
                    Text("#").font(.system(size: size * 0.50, weight: .regular)).offset(y: 1)
                } else {
                    VStack(spacing: -2) {
                        Text(key.digit)
                            .font(.system(size: size * 0.475, weight: .regular))
                        Text(key.sub.isEmpty ? " " : key.sub)
                            .font(.system(size: max(9, size * 0.125), weight: .semibold))
                            .tracking(1.8)
                    }
                }
            }
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background {
                if #available(iOS 26.0, *) {
                    Circle().fill(.clear).glassEffect(.regular.interactive(), in: Circle())
                } else {
                    Circle().fill(Color(.systemGray5))
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(key.digit)
        .accessibilityIdentifier("dial-key-\(key.digit)")
        .onLongPressGesture(minimumDuration: 0.5, pressing: { pressing in
            if pressing { insertedPlus = false }
        }) {
            if let onPlus {
                insertedPlus = true
                onPlus()
            } else {
                onDigit(key.digit)
                insertedPlus = true
            }
        }
    }
}

private struct DialKey: Identifiable, Hashable {
    let digit: String
    let sub: String
    var id: String { digit }

    init(_ digit: String, sub: String) {
        self.digit = digit
        self.sub = sub
    }
}
