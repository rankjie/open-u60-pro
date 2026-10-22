import SwiftUI
import UIKit

enum KeyboardDismissal {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private struct KeyboardDismissalModifier: ViewModifier {
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if visible {
                        Spacer()
                        Button("Done") { KeyboardDismissal.dismiss() }
                            .accessibilityIdentifier("dismiss-keyboard")
                    }
                }
            }
            .onAppear { visible = true }
            .onDisappear { visible = false }
    }
}

extension View {
    func keyboardDismissal() -> some View { modifier(KeyboardDismissalModifier()) }
}
