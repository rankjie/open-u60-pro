import SwiftUI

struct CardView<Content: View>: View {
    let content: Content
    let padding: CGFloat

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct SettingsRow: View {
    static let insets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
    let title: String
    let icon: String
    var color: Color = .blue
    /// The current state, shown trailing like iOS Settings; empty hides it.
    var value: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(color, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.primary)
                .layoutPriority(1)
            if let value, !value.isEmpty {
                Spacer(minLength: 8)
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

/// Build a destination's model only when pushed, and retain it across navigation updates.
struct PushedModelHost<Model, Content: View>: View {
    @State private var box: LazyModelBox<Model>
    private let content: (Model) -> Content

    init(_ model: @autoclosure @escaping () -> Model, @ViewBuilder content: @escaping (Model) -> Content) {
        _box = State(wrappedValue: LazyModelBox(model))
        self.content = content
    }

    var body: some View { content(box.model) }
}

@MainActor
private final class LazyModelBox<Model> {
    lazy var model: Model = build()
    private let build: () -> Model

    init(_ build: @escaping () -> Model) { self.build = build }
}
