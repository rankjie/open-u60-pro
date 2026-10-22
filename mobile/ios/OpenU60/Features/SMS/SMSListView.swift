import SwiftUI
import Combine

struct SMSListView: View {
    @Environment(SMSNotificationManager.self) private var notifications
    @State private var messagePath: [String] = []
    var viewModel: SMSViewModel
    let client: AgentClient
    let authManager: AuthManager
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
                    ForEach(filteredConversations) { conversation in
                        NavigationLink(value: conversation.id) {
                            SMSConversationRow(conversation: conversation, now: now)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await viewModel.deleteConversation(conversation) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 16))
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 76 }
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

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(conversation.unreadCount > 0 ? Color.blue : Color.clear)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Image(systemName: "person.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color(.systemGray3), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conversation.number)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(timestamp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(conversation.latestMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(conversation.messages.last?.lineLabel ?? "Line unknown")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 64)
        .accessibilityElement(children: .combine)
        .accessibilityValue(conversation.unreadCount > 0 ? "\(conversation.unreadCount) unread messages" : "")
    }

    private var timestamp: String {
        let calendar = Calendar.autoupdatingCurrent
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: conversation.latestTime),
                                            to: calendar.startOfDay(for: now)).day
        if days == 0 { return conversation.latestTime.formatted(date: .omitted, time: .shortened) }
        if days == 1 { return "Yesterday" }
        if let days, (2..<7).contains(days) { return conversation.latestTime.formatted(.dateTime.weekday(.wide)) }
        return conversation.latestTime.formatted(date: .numeric, time: .omitted)
    }
}
