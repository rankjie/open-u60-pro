import SwiftUI

struct SMSComposeView: View {
    var viewModel: SMSViewModel
    var onSent: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""
    @State private var messageText = ""
    @FocusState private var numberFocused: Bool
    @FocusState private var messageFocused: Bool

    private var charInfo: String {
        let encType = SMSParser.getEncodeType(messageText)
        let maxPerSegment = encType == "UNICODE" ? 67 : 153
        let maxTotal = encType == "UNICODE" ? 335 : 765
        let segments = messageText.isEmpty ? 0 : (messageText.count + maxPerSegment - 1) / maxPerSegment
        return "\(messageText.count)/\(maxTotal) (\(segments) SMS)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("To:")
                        .foregroundStyle(.secondary)
                    TextField("Phone number", text: $number)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .focused($numberFocused)
                        .accessibilityLabel("Recipient")
                        .accessibilityIdentifier("sms-recipient")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .disabled(viewModel.isSending)
                Divider().padding(.leading, 20)
                Spacer(minLength: 0)
            }
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 4) {
                    if let error = viewModel.error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 20)
                    }
                    if !messageText.isEmpty {
                        Text(charInfo)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 24)
                    }
                    SMSInputBar(text: $messageText, isFocused: $messageFocused, isSending: viewModel.isSending,
                                canSend: !number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        let recipient = number
                        let message = messageText
                        Task {
                            if await viewModel.sendSMS(to: recipient, message: message) {
                                onSent(recipient)
                                dismiss()
                            }
                        }
                    }
                    .disabled(viewModel.isSending)
                }
                .padding(.top, 4)
                .background(.bar)
            }
            .navigationTitle("New Message")
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if numberFocused || messageFocused {
                        Button("Hide keyboard", systemImage: "keyboard.chevron.compact.down") {
                            numberFocused = false
                            messageFocused = false
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("dismiss-keyboard")
                    }
                }
            }
            .onAppear { numberFocused = true }
        }
    }
}

struct SMSInputBar: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let isSending: Bool
    var canSend = true
    let onSend: () -> Void

    private var sendEnabled: Bool {
        canSend && !isSending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            TextField("Text Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($isFocused)
                .padding(.leading, 14)
                .padding(.vertical, 11)
                .accessibilityLabel("Message")
                .accessibilityIdentifier("sms-message-input")
            Group {
                if isSending {
                    ProgressView()
                        .accessibilityLabel("Sending message")
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(sendEnabled ? Color.green : Color(.systemGray3))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!sendEnabled)
                    .accessibilityLabel("Send message")
                    .accessibilityIdentifier("sms-send")
                }
            }
            .frame(width: 44, height: 44)
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Color(.separator), lineWidth: 0.5) }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
