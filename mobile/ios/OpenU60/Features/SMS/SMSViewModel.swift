import SwiftUI
import os

private let logger = Logger(subsystem: "com.zte.companion", category: "SMS")

/// Hands a decoded JSON payload to a background task. Safe because the value is transferred
/// exactly once, is never mutated, and the sender drops it at the call site.
private struct UncheckedTransfer<T>: @unchecked Sendable {
    let value: T
}

@MainActor protocol SMSRemote: AnyObject {
    func postJSON(_ path: String, body: [String: Any]) async throws -> [String: Any]
    func getJSON(_ path: String, retryOnUnauthorized: Bool) async throws -> [String: Any]
}
extension AgentClient: SMSRemote {}

@Observable
@MainActor
final class SMSViewModel {
    var conversations: [SMSConversation] = []
    var allMessages: [SMSMessage] = []
    var capacity: SMSCapacity = .empty
    var isLoading = false
    var isSending = false
    var error: String?

    private struct Inbox: Codable {
        let messages: [SMSMessage]
        let capacity: SMSCapacity
        var events: [UUID]? = nil
        var parts: [SMSDelivery]? = nil
        var deleted: [String: Date]? = nil
        var refreshedAt: Date? = nil
        var complete: Bool? = nil
    }
    private let client: any SMSRemote
    private let identity: () -> UUID?
    private let cache: DeviceSnapshotCache<Inbox>
    private var routerID: UUID?
    private var lastRefresh: Date?
    private var requestID: UUID?
    private var mutationRevision = 0
    private var events: [UUID] = []
    private var parts: [SMSDelivery] = []
    private var deleted: [String: Date] = [:]
    private var complete = false
    private(set) var needsReconciliation = true
    private var refreshAgain = false
    private var refreshTask: Task<Void, Never>?
    private var cacheNeedsSave = true

    init(client: any SMSRemote, identity: @escaping () -> UUID?,
         directory: URL = .applicationSupportDirectory.appending(path: "Messages", directoryHint: .isDirectory)) {
        self.client = client
        self.identity = identity
        self.cache = DeviceSnapshotCache(directory: directory)
        loadCached()
    }

    func loadCached() {
        let selected = identity()
        guard selected != routerID else { return }
        refreshTask?.cancel(); refreshTask = nil
        routerID = selected; requestID = nil; isLoading = false; refreshAgain = false
        lastRefresh = nil; error = nil
        events = []; parts = []; deleted = [:]; complete = false; needsReconciliation = true
        cacheNeedsSave = true
        allMessages = []; conversations = []; capacity = .empty
        guard let selected else { return }
        do {
            if let saved = try cache.load(routerID: selected) {
                setMessages(saved.messages); capacity = saved.capacity; cacheNeedsSave = false
                events = saved.events ?? []; parts = saved.parts ?? []; deleted = saved.deleted ?? [:]
                lastRefresh = saved.refreshedAt; complete = saved.complete ?? true
                needsReconciliation = !complete || !parts.isEmpty
            }
        } catch { self.error = "Could not load messages on this iPhone: \(error.localizedDescription)" }
    }

    @discardableResult private func setMessages(_ messages: [SMSMessage]) -> Bool {
        guard allMessages != messages else { return false }
        let changed = allMessages.reconcile(with: messages)
        if changed { conversations.reconcile(with: SMSParser.groupIntoConversations(allMessages)) }
        return changed
    }

    private func saveCache() {
        guard let routerID, identity() == routerID else { return }
        cacheNeedsSave = true
        do {
            try cache.save(Inbox(messages: allMessages, capacity: capacity, events: events, parts: parts,
                deleted: deleted, refreshedAt: lastRefresh, complete: complete), routerID: routerID)
            cacheNeedsSave = false
        }
        catch { self.error = "Could not save messages on this iPhone: \(error.localizedDescription)" }
    }

    // MARK: - Fetch

    func invalidate() {
        needsReconciliation = true
        lastRefresh = nil
        if refreshTask != nil { refreshAgain = true }
    }

    /// Push data is committed to the same cache and state as API reads, even with no Messages view.
    func receive(_ payload: [String: Any]) {
        loadCached()
        do {
            let delivery = try SMSDelivery(payload)
            guard delivery.routerID == routerID, delivery.messageID > 0 else { return }
            guard delivery.expiresAt.map({ $0 > Date().timeIntervalSince1970 }) ?? true else { return }
            if events.contains(delivery.eventID) { if cacheNeedsSave { saveCache() }; return }
            guard delivery.metadata != nil else { invalidate(); return }
            parts.removeAll { $0.expiresAt.map { $0 <= Date().timeIntervalSince1970 } ?? false }
            if let old = parts.first(where: { $0.eventID == delivery.eventID && $0.part == delivery.part }) {
                guard old == delivery else { throw SMSDeliveryError.conflictingParts }
                return
            }
            guard Set(parts.map(\.eventID)).count < 128 || parts.contains(where: { $0.eventID == delivery.eventID }) else { throw SMSDeliveryError.invalid }
            parts.append(delivery)
            let assembled = parts.filter { $0.eventID == delivery.eventID }.sorted { $0.part < $1.part }
            guard assembled.allSatisfy({ $0.parts == delivery.parts && $0.messageID == delivery.messageID && $0.sender == delivery.sender && $0.metadata == delivery.metadata }),
                  assembled.reduce(0, { $0 + $1.text.utf8.count }) <= 65536 else { throw SMSDeliveryError.conflictingParts }
            guard assembled.count == delivery.parts else { saveCache(); return }
            var message = try delivery.message(content: assembled.map(\.text).joined())
            deleted = deleted.filter { Date().timeIntervalSince($0.value) < 90000 }
            if deleted[message.storageKey] == nil {
                var updated = allMessages
                if let index = updated.firstIndex(where: { $0.id == message.id }) {
                    let previous = updated[index]
                    if previous.storageKey == message.storageKey {
                        if previous.tag == .read { message = SMSMessage(id: message.id, number: message.number, content: message.content,
                            date: message.date, tag: .read, groupId: message.groupId, memStore: message.memStore, line: previous.line ?? message.line) }
                        updated[index] = message
                    } else if previous.date <= message.date { updated[index] = message }
                } else { updated.append(message) }
                setMessages(updated.sorted { $0.id > $1.id })
            }
            parts.removeAll { $0.eventID == delivery.eventID }
            events.append(delivery.eventID); if events.count > 1024 { events.removeFirst(events.count - 1024) }
            mutationRevision += 1
            if complete { lastRefresh = Date() }
            needsReconciliation = !complete
            if !complete { refreshAgain = true }
            saveCache()
        } catch {
            self.error = error.localizedDescription
            invalidate()
        }
    }

    func refresh(force: Bool = true) async {
        loadCached()
        if let refreshTask { await refreshTask.value; return }
        let router = routerID
        if !force, !needsReconciliation, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 30 { return }
        let id = UUID()
        requestID = id; isLoading = true
        // A tab disappearing must not cancel the inbox update needed by the next visit.
        let task = Task { await self.fetchSnapshot(router: router, id: id) }
        refreshTask = task
        await task.value
        if requestID == id { isLoading = false; requestID = nil; refreshTask = nil }
    }

    private func fetchSnapshot(router: UUID?, id: UUID) async {
        repeat {
            refreshAgain = false
            let revision = mutationRevision
            async let capacityResult = self.fetchCapacity()
            do {
                let messages = try await fetchMessages()
                let cap = await capacityResult
                try Task.checkCancellation()
                guard identity() == router, routerID == router, requestID == id else { loadCached(); return }
                // A read/delete acknowledged after this request began owns the newer state.
                guard revision == mutationRevision else { continue }
                error = nil
                let messagesChanged = setMessages(messages)
                let capacityChanged = cap.map { $0 != capacity } ?? false
                if let cap, capacityChanged { capacity = cap }
                lastRefresh = Date()
                complete = true; needsReconciliation = false
                if messagesChanged || capacityChanged || cacheNeedsSave { saveCache() }
            } catch {
                _ = await capacityResult
                guard identity() == router, requestID == id else { loadCached(); return }
                if error.isCancellation { return }
                self.error = error.localizedDescription
            }
        } while refreshAgain && !Task.isCancelled
    }

    private func fetchMessages() async throws -> [SMSMessage] {
        let data = try await client.postJSON("/api/sms/list", body: [
            "page": 0,
            "data_per_page": 500,
            "mem_store": 2, // Unified inbox: device and SIM storage.
            "tags": 10,
            "order_by": "order by id desc"
        ])
        guard data["messages"] is [[String: Any]] else {
            throw AgentError.decodingError("The SMS list is missing its messages array.")
        }
        return try await Self.parseMessagesOffMain(data)
    }

    /// A full page is 500 messages, each needing a UCS-2 decode and a date build. That is far
    /// too much work to do between two frames, so it runs off the main actor.
    private static func parseMessagesOffMain(_ data: [String: Any]) async throws -> [SMSMessage] {
        let payload = UncheckedTransfer(value: data)
        return try await Task.detached(priority: .userInitiated) {
            try SMSParser.parseMessages(payload.value)
        }.value
    }

    private func fetchCapacity() async -> SMSCapacity? {
        do {
            let data = try await client.getJSON("/api/sms/capacity", retryOnUnauthorized: true)
            return SMSParser.parseCapacity(data)
        } catch {
            guard !error.isCancellation else { return nil }
            logger.warning("fetchCapacity: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Send

    func sendSMS(to number: String, message: String) async -> Bool {
        loadCached()
        let router = routerID
        isSending = true
        defer { isSending = false }
        error = nil

        let encodeType = SMSParser.getEncodeType(message)
        let body = SMSParser.encodeUCS2Hex(message)
        let smsTime = SMSParser.formatSMSTime()

        do {
            let _ = try await client.postJSON("/api/sms/send", body: [
                "number": number,
                "sms_time": smsTime,
                "message_body": body,
                "id": "-1",
                "encode_type": encodeType
            ])
            guard identity() == router else { loadCached(); return false }
            mutationRevision += 1; lastRefresh = nil
            logger.info("SMS send confirmed")
            isSending = false
            await refresh()
            return true
        } catch {
            isSending = false
            guard !error.isCancellation else { return false }
            logger.error("sendSMS: \(error.localizedDescription)")
            self.error = "Failed to send: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Delete

    func deleteMessages(ids: [Int]) async {
        loadCached()
        let router = routerID
        let idStr = ids.map(String.init).joined(separator: ";") + ";"

        do {
            let _ = try await client.postJSON("/api/sms/delete", body: ["id": idStr])
            guard identity() == router else { loadCached(); return }
            mutationRevision += 1; lastRefresh = nil
            let deleted = Set(ids)
            for message in allMessages where deleted.contains(message.id) { self.deleted[message.storageKey] = Date() }
            setMessages(allMessages.filter { !deleted.contains($0.id) })
            saveCache()
            logger.info("SMS deletion confirmed")
            await refresh()
        } catch {
            guard !error.isCancellation else { return }
            logger.error("deleteMessages: \(error.localizedDescription)")
            self.error = "Delete failed: \(error.localizedDescription)"
        }
    }

    func deleteConversation(_ conversation: SMSConversation) async {
        let ids = conversation.messages.map(\.id)
        await deleteMessages(ids: ids)
    }

    // MARK: - Mark Read

    func markAsRead(ids: [Int]) async {
        loadCached()
        let router = routerID
        guard !ids.isEmpty else { return }
        let idStr = ids.map(String.init).joined(separator: ";") + ";"

        do {
            let _ = try await client.postJSON("/api/sms/read", body: ["id": idStr, "tag": 0])
            guard identity() == router else { loadCached(); return }
            mutationRevision += 1
            // Update local state without full refresh
            let markedIds = Set(ids)
            for i in allMessages.indices where markedIds.contains(allMessages[i].id) {
                let msg = allMessages[i]
                allMessages[i] = SMSMessage(
                    id: msg.id, number: msg.number, content: msg.content,
                    date: msg.date, tag: .read, groupId: msg.groupId, memStore: msg.memStore, line: msg.line
                )
            }
            conversations.reconcile(with: SMSParser.groupIntoConversations(allMessages))
            saveCache()
        } catch {
            guard !error.isCancellation else { return }
            logger.warning("markAsRead: \(error.localizedDescription)")
        }
    }
}
