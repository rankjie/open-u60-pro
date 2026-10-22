import SwiftUI
import Combine

struct SMSListView: View {
    @Environment(SMSNotificationManager.self) private var notifications
    var viewModel: SMSViewModel
    let client: AgentClient
    let authManager: AuthManager
    /// Owned by the tab container so Home can open a thread directly.
    @Binding var messagePath: [String]
    @State private var showCompose = false
    @State private var searchText = ""


    /// Reference point every row's relative timestamp is measured from.
    @State private var now = Date()

    /// One coarse ticker for the whole list instead of a per-row `Text(_, style: .relative)`
    /// timer — minute-granularity labels don't need a faster cadence. Held in `@State` so it
    /// survives body re-evaluation; `.common` mode keeps it running while scrolling.
    @State private var ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var filteredConversations: [SMSConversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.conversations }
        return viewModel.conversations.filter { conversation in
            conversation.number.localizedCaseInsensitiveContains(query)
                || conversation.messages.contains { $0.content.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationStack(path: $messagePath) {
            List {
                if let error = viewModel.error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section {
                    let showsLine = Set(viewModel.allMessages.map(\.lineLabel)).count > 1
                    ForEach(filteredConversations) { conversation in
                        NavigationLink(value: conversation.id) {
                            SMSConversationRow(conversation: conversation, now: now, showsLine: showsLine)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await viewModel.deleteConversation(conversation) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 16))
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 72 }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Messages")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: String.self) { conversationId in
                if let conversation = viewModel.conversations.first(where: { $0.id == conversationId }) {
                    SMSConversationView(viewModel: viewModel, conversation: conversation)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        NavigationLink {
                            MessageSettingsView(client: client, authManager: authManager)
                        } label: {
                            Label("Message settings", systemImage: "gearshape")
                        }
                        if viewModel.capacity.nvTotal + viewModel.capacity.simTotal > 0 {
                            Section("Storage") {
                                Text("\(viewModel.capacity.nvUsed + viewModel.capacity.simUsed) of \(viewModel.capacity.nvTotal + viewModel.capacity.simTotal) messages")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Message options")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCompose = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New Message")
                    .accessibilityIdentifier("sms-compose")
                }
            }
            .searchable(text: $searchText, prompt: "Search messages")
            .refreshable { await viewModel.refresh() }
            .overlay {
                if viewModel.isLoading && viewModel.conversations.isEmpty {
                    ProgressView()
                } else if !viewModel.isLoading && viewModel.conversations.isEmpty && viewModel.error == nil {
                    ContentUnavailableView(
                        "No Messages",
                        systemImage: "message",
                        description: Text("SMS messages will appear here")
                    )
                } else if filteredConversations.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .sheet(isPresented: $showCompose) {
                SMSComposeView(viewModel: viewModel) { number in
                    let id = SMSParser.normalizeNumber(number)
                    if viewModel.conversations.contains(where: { $0.id == id }) { messagePath = [id] }
                }
            }
            .onReceive(ticker) { now = $0 }
            .task(id: notifications.openRevision) {
                if let id = notifications.takeOpenMessageID(), let messageID = Int(id),
                   let conversation = viewModel.conversations.first(where: { $0.messages.contains { $0.id == messageID } }) {
                    messagePath = [conversation.id]
                }
            }
        }
    }
}

// MARK: - Conversation Row

private struct SMSConversationRow: View {
    let conversation: SMSConversation
    /// Bumped by the list's ticker, so the timestamp keeps up without a timer of its own.
    let now: Date
    /// The line is only worth a row when the inbox spans more than one.
    let showsLine: Bool

    var body: some View {
        let unread = conversation.unreadCount > 0
        let latest = conversation.messages.last
        let code = latest.flatMap { $0.tag.isIncoming && now.timeIntervalSince($0.date) < 86400 ? SMSParser.verificationCode(in: $0.content) : nil }
        let brand = conversation.brand
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(unread ? Color.blue : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 18)
                .accessibilityHidden(true)
            ContactAvatar(number: conversation.number, name: brand)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(brand ?? conversation.number)
                        .font(.body.weight(unread ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(timestamp)
                        .font(.caption.weight(unread ? .semibold : .regular))
                        .foregroundStyle(unread ? Color.blue : Color.secondary)
                        .lineLimit(1)
                }
                Text(conversation.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if code != nil || showsLine || brand != nil {
                    HStack(spacing: 8) {
                        if let code { CodeChip(code: code) }
                        Facts(brand == nil ? nil : conversation.number, showsLine ? latest?.lineLabel ?? "Line unknown" : nil)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(conversation.unreadCount > 0 ? "\(conversation.unreadCount) unread messages" : "")
    }

    private var timestamp: String { SMSTimestamp.short(conversation.latestTime, now: now) }
}

enum SMSTimestamp {
    static func short(_ date: Date, now: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                            to: calendar.startOfDay(for: now)).day
        if days == 0 { return date.formatted(date: .omitted, time: .shortened) }
        if days == 1 { return String(localized: "Yesterday") }
        if let days, (2..<7).contains(days) { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
