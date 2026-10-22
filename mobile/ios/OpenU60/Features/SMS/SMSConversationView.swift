import SwiftUI

struct SMSConversationView: View {
    var viewModel: SMSViewModel
    let conversation: SMSConversation
    @State private var messageText = ""
    @State private var sendFailure: String?
    @FocusState private var messageFocused: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var messages: [SMSMessage] {
        viewModel.conversations.first(where: { $0.id == conversation.id })?.messages ?? conversation.messages
    }

    private var timeline: [MessageTimelineItem] {
        let messages = messages
        return messages.enumerated().map { index, message in
            let showDate = index == 0 || message.date.timeIntervalSince(messages[index - 1].date) > 300
                || !Calendar.autoupdatingCurrent.isDate(message.date, inSameDayAs: messages[index - 1].date)
            // The line is stated where it starts or changes, not under every bubble.
            let showsLine = showDate || message.line != messages[index - 1].line
            return MessageTimelineItem(message: message, showDate: showDate, showsLine: showsLine)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(timeline) { item in
                        if item.showDate {
                            Text(item.message.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.top, 12)
                                .padding(.bottom, 6)
                                .frame(maxWidth: .infinity)
                        }
                        SMSBubbleView(message: item.message,
                                      isLatest: item.message.id == messages.last?.id,
                                      showsLine: item.showsLine)
                            .id(item.message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            // Lands on the newest message at first layout, unlike an onAppear scrollTo
            // that fires before the LazyVStack has materialized its rows.
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.count) {
                guard let lastId = messages.last?.id else { return }
                withAnimation {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let sendFailure {
                    Label(sendFailure, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
                SMSInputBar(text: $messageText, isFocused: $messageFocused, isSending: viewModel.isSending) {
                    let text = messageText
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    sendFailure = nil
                    Task {
                        // Only clear the field once the agent accepted it, so a failed send
                        // leaves the user's text intact to retry.
                        if await viewModel.sendSMS(to: conversation.number, message: text) {
                            if messageText == text { messageText = "" }
                        } else {
                            sendFailure = viewModel.error ?? "Message not sent"
                        }
                    }
                }
            }
            .background(.bar)
        }
        .navigationTitle(conversation.displayName)
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(horizontalSizeClass == .regular ? .automatic : .hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if messageFocused {
                    Button("Hide keyboard", systemImage: "keyboard.chevron.compact.down") {
                        messageFocused = false
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("dismiss-keyboard")
                }
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    ContactAvatar(number: conversation.number, name: conversation.brand, size: 28)
                    Text(conversation.displayName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .task(id: messages.filter { $0.tag == .unread }.map(\.id)) {
            // Mark unread messages as read when conversation is opened
            let unreadIds = messages.filter { $0.tag == .unread }.map(\.id)
            await viewModel.markAsRead(ids: unreadIds)
        }
    }
}

private struct MessageTimelineItem: Identifiable {
    let message: SMSMessage
    let showDate: Bool
    let showsLine: Bool
    var id: Int { message.id }
}

// MARK: - Bubble View

private struct SMSBubbleView: View {
    let message: SMSMessage
    let isLatest: Bool
    let showsLine: Bool

    private var isOutgoing: Bool { !message.tag.isIncoming }

    var body: some View {
        HStack {
            if isOutgoing { Spacer(minLength: 60) }

            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(isOutgoing ? Color.green : Color(.systemGray5), in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(isOutgoing ? .white : .primary)
                    .textSelection(.enabled)
                if !isOutgoing, let code = SMSParser.verificationCode(in: message.content) {
                    CodeChip(code: code).padding(.top, 2)
                }

                HStack(spacing: 4) {
                    if showsLine, let line = message.line {
                        Text("\(isOutgoing ? "From" : "To") \(line.label)")
                            .foregroundStyle(.secondary)
                    }
                    if message.tag == .failed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption2)
                            .accessibilityLabel("Not delivered")
                    }
                    if message.tag == .failed {
                        Text("Not Delivered").foregroundStyle(.red)
                    } else if message.tag == .draft {
                        Text("Draft").foregroundStyle(.secondary)
                    } else if isLatest && message.tag == .sent {
                        Text("Sent").foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
                .padding(.horizontal, 6)
            }

            if !isOutgoing { Spacer(minLength: 60) }
        }
    }
}
