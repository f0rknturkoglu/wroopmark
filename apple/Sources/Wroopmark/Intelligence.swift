import AppKit
import Foundation

// On-device intelligence (v0.3): meaning search, vectors in the background,
// summaries and tag ideas, related items; plus automatic rules and the
// duplicates view (v0.2). The models run in `wroopmark-ai`, a helper the
// core starts on demand and that quits after a minute idle, so none of
// this stays in the app's memory.
extension AppModel {
    // MARK: - Search

    /// True when the search has words of its own (not only filters).
    static func hasWords(_ q: String) -> Bool {
        q.split(whereSeparator: \.isWhitespace).contains { tok in
            let t = String(tok)
            if t.hasPrefix("\"") { return true }
            return !t.hasPrefix("-") && !t.hasPrefix("@") && !t.contains(":")
        }
    }

    /// The core command for a page of results: meaning search when it is on
    /// and there are words, the plain search otherwise.
    func searchCommand(q: String, sort: String, limit: Int, offset: Int) -> CoreCommand {
        guard semanticSearch, Self.hasWords(q) else {
            return .search(q: q, sort: sort, limit: limit, offset: offset)
        }
        return .call("semantic_search", ["q": .string(q), "sort": .string(sort), "limit": .int(Int64(limit)), "offset": .int(Int64(offset))])
    }

    // MARK: - Status and vectors

    func loadAIStatus() async {
        do {
            let s: AIStatus = try await core.call(.call("ai_status", [:]))
            if s != aiStatus { aiStatus = s }
        } catch is CancellationError {
            return
        } catch {
            aiStatus = nil
        }
    }

    /// Works through items without a vector, 64 at a time, at low priority.
    /// Stops when done, when indexing is off, or for a while after an error
    /// (no helper, model not downloaded yet).
    func startEmbedding() {
        guard aiIndexing, embedTask == nil, embedPausedUntil.map({ $0 < .now }) ?? true else { return }
        embedTask = Task(priority: .background) { [weak self] in
            defer { self?.embedTask = nil }
            while let self, self.aiIndexing, !Task.isCancelled {
                do {
                    let r: EmbedReport = try await self.core.call(.call("embed_pending", ["limit": .int(64)]))
                    if r.done == 0 || r.remaining == 0 { break }
                    try await Task.sleep(for: .milliseconds(400))
                } catch is CancellationError {
                    break
                } catch {
                    self.embedPausedUntil = .now + 1800
                    break
                }
            }
            await self?.loadAIStatus()
        }
    }

    func rebuildVectors() async {
        embedTask?.cancel()
        embedTask = nil
        embedPausedUntil = nil
        _ = await perform(.call("clear_vectors", [:]))
        startEmbedding()
        await loadAIStatus()
    }

    // MARK: - Related, summaries

    func loadRelated(for id: String) async {
        guard relatedFor != id else { return }
        relatedFor = id
        do {
            let list: [Item] = try await core.call(.call("related", ["id": .string(id), "limit": .int(6)]))
            guard relatedFor == id else { return }
            related = list
        } catch {
            if relatedFor == id { related = [] }
        }
    }

    func summarize(_ id: String) async {
        guard !summarizing.contains(id) else { return }
        summarizing.insert(id)
        summaryError = nil
        defer { summarizing.remove(id) }
        do {
            let item: Item = try await core.call(.call("summarize", ["id": .string(id)]))
            if let i = items.firstIndex(where: { $0.id == id }) { items[i] = item }
        } catch is CancellationError {
            return
        } catch {
            summaryError = error.localizedDescription
        }
    }

    /// Summarizes the next few triage cards ahead of time.
    func prefetchSummaries(after id: String) {
        guard aiStatus?.llmReady == true, let start = items.firstIndex(where: { $0.id == id }) else { return }
        let upcoming = items[start...].prefix(3).filter { $0.summary == nil && !summarizing.contains($0.id) }
        guard !upcoming.isEmpty else { return }
        Task(priority: .utility) { [weak self] in
            for item in upcoming { await self?.summarize(item.id) }
        }
    }

    func acceptAITag(_ tag: String, on id: String) async {
        await editTags([id], add: [tag], remove: [])
    }

    // MARK: - Rules

    func loadRules() async {
        do {
            rules = try await core.call(.call("rules", [:]))
            rulesError = nil
        } catch is CancellationError {
            return
        } catch {
            rulesError = error.localizedDescription
        }
    }

    /// How many items a rule's search finds now (for the editor).
    func ruleMatches(_ query: String) async -> Int? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        return try? await core.call(.call("count", ["q": .string(q)]), as: Int.self)
    }

    @discardableResult
    func addRule(query: String, tag: String?, folderID: Int64?, apply: Bool) async -> Bool {
        struct Added: Decodable, Sendable { let applied: Int }
        do {
            let r: Added = try await core.call(.call("add_rule", [
                "query": .string(query), "tag": tag.arg, "folder_id": folderID.arg, "apply": .bool(apply),
            ]))
            rulesError = nil
            await loadRules()
            if r.applied > 0 {
                await refreshLoaded()
                await refreshMeta(force: true)
            }
            return true
        } catch {
            rulesError = error.localizedDescription
            return false
        }
    }

    func setRule(_ rule: RuleRow, enabled: Bool) async {
        _ = await perform(.call("update_rule", [
            "id": .int(rule.id), "query": .string(rule.query), "tag": rule.tag.arg, "folder_id": rule.folderId.arg, "enabled": .bool(enabled),
        ]))
        await loadRules()
    }

    func deleteRule(_ rule: RuleRow) async {
        _ = await perform(.call("delete_rule", ["id": .int(rule.id)]))
        await loadRules()
    }

    func applyRule(_ rule: RuleRow) async {
        _ = await perform(.call("apply_rule", ["id": .int(rule.id)]))
        await loadRules()
        await refreshLoaded()
        await refreshMeta(force: true)
    }

    // MARK: - Duplicates

    func loadDuplicates() async {
        isLoadingDuplicates = true
        defer { isLoadingDuplicates = false }
        do {
            duplicates = try await core.call(.call("duplicates", [:]))
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func ignoreDuplicates(_ group: DuplicateGroup) async {
        duplicates.removeAll { $0.id == group.id }
        _ = await perform(.call("ignore_duplicates", ["ids": .strings(group.items.map(\.id))]))
    }

    /// Keeps `keep` and deletes the rest of the group.
    func keepOnly(_ keep: Item, in group: DuplicateGroup) async {
        let drop = group.items.map(\.id).filter { $0 != keep.id }
        duplicates.removeAll { $0.id == group.id }
        await delete(drop)
    }
}
