import Foundation

@MainActor
func checkPreferenceLearning() async throws -> Int {
    let snapshot = AssetSnapshot(modified: nil, width: 100, height: 100, favorite: false)
    func feedback(_ index: Int, group: String? = nil, action: PhotoDecision = .keep) -> OwnerFeedback {
        OwnerFeedback(id: UUID(), assetID: "private-asset-\(index)", snapshot: snapshot, action: action,
            reason: "owner-reason-\(index)", modelObservation: "unconfirmed", date: Date(), learningGroup: group)
    }
    // A fake model that merges repeated choices while preserving every source receipt.
    func compress(_ content: [[String: Any]]) throws -> String {
        let input = try JSONSerialization.jsonObject(with: Data((content[0]["text"] as! String).utf8)) as! [String: Any]
        let previous = (input["已有归纳"] as! [String: Any])["rules"] as! [[String: Any]]
        var evidence: [String: [String]] = [:]
        for rule in previous { evidence[rule["action"] as! String, default: []] += rule["evidence"] as! [String] }
        for item in input["新增反馈"] as! [[String: String]] {
            evidence[item["用户选择"]!, default: []].append(item["source"]!)
        }
        return PreferenceDigest.json(["rules": evidence.keys.sorted().map { action in
            ["condition": "压缩后的具体条件", "action": action, "exceptions": "保留不确定性", "evidence": evidence[action]!] as [String: Any]
        }])
    }
    var calls = 0
    let many = (0..<75).map { feedback($0) }
    let digest = try await PreferenceLearner.compact(PreferenceDigest(), feedback: many) { content, _ in
        calls += 1
        precondition(!(content[0]["text"] as! String).contains("private-asset"))
        return try compress(content)
    }
    precondition(calls == 1 && digest.rules.count == 1 && digest.rules[0].evidence.count == 75)
    precondition(digest.prompt(for: many).count < 400 && !digest.prompt(for: many).contains("待归纳反馈\":[{"))
    precondition(digest.rules[0].evidence.contains(many[0].id)) // oldest preference survives >24/20
    _ = try await PreferenceLearner.compact(digest, feedback: many) { _, _ in fatalError("Unchanged memory was recompressed") }
    // A normal 119-example history takes one call, with short wire references and UUIDs only on disk.
    let history = (0..<119).map { feedback($0) }
    var historyCalls = 0
    let quick = try await PreferenceLearner.compact(PreferenceDigest(), feedback: history) { content, _ in
        historyCalls += 1
        let payload = content[0]["text"] as! String
        precondition(history.allSatisfy { !payload.contains($0.id.uuidString) })
        return try compress(content)
    }
    precondition(historyCalls == 1 && Set(quick.rules.flatMap(\.evidence)) == Set(history.map(\.id)))
    // Interrupted work resumes from the last validated checkpoint instead of starting over.
    let large = (0..<300).map { feedback($0) }
    var saved = PreferenceDigest(), attempts = 0
    enum Interrupted: Error { case stopped }
    do {
        _ = try await PreferenceLearner.compact(PreferenceDigest(), feedback: large, request: { content, _ in
            attempts += 1
            if attempts == 2 { throw Interrupted.stopped }
            return try compress(content)
        }, checkpoint: { saved = $0 })
        fatalError("Injected failure was ignored")
    } catch Interrupted.stopped {}
    precondition(saved.rules.flatMap(\.evidence).count == 128)
    var resumedCalls = 0
    let resumed = try await PreferenceLearner.compact(saved, feedback: large) { content, _ in
        resumedCalls += 1
        return try compress(content)
    }
    precondition(resumedCalls == 2 && Set(resumed.rules.flatMap(\.evidence)) == Set(large.map(\.id)))
    do {
        _ = try await PreferenceLearner.compact(PreferenceDigest(), feedback: many) { _, _ in
            PreferenceDigest.json(["rules": [["condition": "bad", "action": "keep", "exceptions": "", "evidence": ["not-a-source"]]]])
        }
        fatalError("Unknown wire source was accepted")
    } catch {}
    // Mirror the actual 119-source mix: cache 107 reasonless examples without asking the model to rewrite them.
    let mixed = (0..<119).map { index in
        OwnerFeedback(id: UUID(), assetID: "mixed-private-\(index)", snapshot: snapshot, action: .keep,
            reason: index < 107 ? "" : "explicit owner reason \(index)",
            modelObservation: "synthetic observation \(index)", date: Date())
    }
    var mixedCalls = 0, mixedSent = 0, localCheckpointCount = 0
    let mixedDigest = try await PreferenceLearner.compact(PreferenceDigest(), feedback: mixed, request: { content, _ in
        mixedCalls += 1
        let payload = try JSONSerialization.jsonObject(with: Data((content[0]["text"] as! String).utf8)) as! [String: Any]
        let examples = payload["新增反馈"] as! [[String: String]]
        precondition(examples.allSatisfy { !$0["用户理由"]!.isEmpty })
        mixedSent += examples.count
        return try compress(content)
    }, checkpoint: { digest in
        localCheckpointCount += 1
        precondition(digest.exampleIDs?.count == 107)
    })
    precondition(mixedCalls == 1 && mixedSent == 12 && localCheckpointCount == 2)
    precondition(Set(mixedDigest.rules.flatMap(\.evidence)).union(mixedDigest.exampleIDs ?? []) == Set(mixed.map(\.id)))
    precondition(mixedDigest.prompt(for: mixed).contains("synthetic observation 0"))
    _ = try await PreferenceLearner.compact(mixedDigest, feedback: mixed) { _, _ in fatalError("Unchanged mix reprocessed") }
    let reasonless = Array(mixed.prefix(107))
    let local = try await PreferenceLearner.compact(PreferenceDigest(), feedback: reasonless) { _, _ in
        fatalError("Reasonless examples triggered a model request")
    }
    precondition(local.rules.isEmpty && Set(local.exampleIDs ?? []) == Set(reasonless.map(\.id)))
    let reloaded = try JSONDecoder().decode(PreferenceDigest.self, from: JSONEncoder().encode(mixedDigest))
    precondition(reloaded.exampleIDs?.count == 107)
    var corrected = many
    corrected[0] = feedback(0, action: .cleanup)
    precondition(digest.validRules(for: corrected).isEmpty)
    let rebuilt = try await PreferenceLearner.compact(digest, feedback: corrected) { content, _ in try compress(content) }
    precondition(Set(rebuilt.rules.flatMap(\.evidence)) == Set(corrected.map(\.id)))
    precondition(!rebuilt.rules.flatMap(\.evidence).contains(many[0].id))
    for bad in ["{}", #"{"rules":[]}"#,
                PreferenceDigest.json(["rules": [["condition": "bad", "action": "cleanup", "exceptions": "", "evidence": [many[0].id.uuidString]]]])] {
        do { _ = try PreferenceDigest.parse(bad, feedback: many); fatalError("Invalid compression accepted") }
        catch {}
    }
    var memory = ReviewMemory()
    memory.feedback = many
    memory.learning = PreferenceLearning(digest: digest)
    let restored = try JSONDecoder().decode(ReviewMemory.self, from: JSONEncoder().encode(memory))
    precondition(restored.learning?.digest.rules[0].evidence.count == 75)
    let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(memory)) as! [String: Any]
    let migrated = try JSONDecoder().decode(ReviewMemory.self,
        from: JSONSerialization.data(withJSONObject: legacy.filter { $0.key != "learning" }))
    precondition(migrated.learning == nil && migrated.latestFeedback.count == 75)
    precondition(migrated.preferencePrompt.contains("owner-reason-0") && migrated.preferencePrompt.contains("owner-reason-74"))

    let keys: [String] = (0..<100).map { "comparison-\($0)" }
    let trainGroups = keys.filter { !PreferenceLearning.isValidationGroup($0) }.prefix(2)
    let heldGroups = keys.filter { PreferenceLearning.isValidationGroup($0) }.prefix(2)
    let train = trainGroups.enumerated().map { feedback($0.offset + 100, group: $0.element) }
    let held = heldGroups.enumerated().flatMap { index, group in
        [feedback(index * 2 + 200, group: group), feedback(index * 2 + 201, group: group, action: .cleanup)]
    }
    let all = train + held
    var requestCount = 0, previewCount = 0
    var failCandidate = false
    let request: PreferenceLearner.Request = { content, instruction in
        requestCount += 1
        let text = PreferenceDigest.json(content) + instruction
        for item in held {
            precondition(!text.contains(item.reason) && !text.contains(item.assetID) && !text.contains(item.id.uuidString))
        }
        precondition(!text.contains("CONTAMINATED-HOLDOUT"))
        if instruction == PreferenceLearner.compressionInstruction { return try compress(content) }
        if instruction.hasPrefix(ReviewProtocol.instruction) {
            let candidate = instruction.contains("candidate-tip")
            let improve = candidate && !failCandidate
            let count = content.filter { ($0["type"] as? String) == "image_url" }.count
            return PreferenceDigest.json(["photos": (0..<count).map { index in
                ["id": String(index + 1), "decision": improve && index.isMultiple(of: 2) ? "keep" : "cleanup",
                 "reason": "visible evidence", "confidence": 0.95] as [String: Any]
            }])
        }
        return #"{"guidance":"candidate-tip"}"#
    }
    let preview: PreferenceLearner.Preview = { _ in previewCount += 1; return Data("synthetic-image".utf8) }
    var initial = PreferenceLearning()
    initial.digest.rules = [PreferenceRule(condition: "CONTAMINATED-HOLDOUT", action: .keep,
        exceptions: "", evidence: [held[0].id])]
    let evolved = try await PreferenceLearner.evolve(initial, feedback: all, model: "test", request: request, preview: preview)
    precondition(evolved.active == 1 && evolved.versions.count == 1 && evolved.versions[0].accepted)
    precondition(evolved.versions[0].baseline.unsafe == 2 && evolved.versions[0].candidate.unsafe == 0)
    precondition(evolved.versions[0].baseline.edits == 2 && evolved.versions[0].candidate.edits == 0)
    precondition(previewCount == 4 && requestCount == 4)
    precondition(!evolved.guidance(for: all, model: "test").isEmpty && evolved.guidance(for: all, model: "other-model").isEmpty)
    _ = try await PreferenceLearner.evolve(evolved, feedback: all, model: "test",
        request: { _, _ in fatalError("Already evaluated feedback repeated") }, preview: { _ in fatalError() })
    failCandidate = true
    let rejected = try await PreferenceLearner.evolve(initial, feedback: all, model: "test", request: request, preview: preview)
    precondition(rejected.active == nil && rejected.versions.count == 1 && !rejected.versions[0].accepted)
    let missing = try await PreferenceLearner.evolve(initial, feedback: all, model: "test",
        request: { _, _ in fatalError("Must not propose before validating available photos") }, preview: { _ in nil })
    precondition(missing.active == nil && missing.lastAttempt.isEmpty && missing.versions.isEmpty)
    let insufficient = try await PreferenceLearner.evolve(initial, feedback: train, model: "test",
        request: { _, _ in fatalError("Insufficient data called model") }, preview: { _ in fatalError() })
    precondition(insufficient.versions.isEmpty && insufficient.status.contains("暂缺"))
    precondition(evolved.activeVersion(for: Array(all.dropFirst())) == nil)
    var rolled = evolved
    rolled.rollback()
    precondition(rolled.active == nil && rolled.digest.rules.count == 1 && rolled.lastAttempt == evolved.lastAttempt)
    let persisted = try JSONDecoder().decode(PreferenceLearning.self, from: JSONEncoder().encode(evolved))
    precondition(persisted.active == 1 && persisted.versions[0].candidate.edits == 0)
    let badRecall = EvolutionScore(groups: 2, keep: 2, cleanup: 4, suggested: 1, unsafe: 0, correctCleanup: 1, edits: 1)
    let baseline = EvolutionScore(groups: 2, keep: 2, cleanup: 4, suggested: 3, unsafe: 1, correctCleanup: 2, edits: 3)
    precondition(!badRecall.improves(on: baseline))
    let badUnsafe = EvolutionScore(groups: 2, keep: 2, cleanup: 4, suggested: 4, unsafe: 2, correctCleanup: 2, edits: 2)
    precondition(!badUnsafe.improves(on: baseline))
    let oneGroupBaseline = EvolutionScore(groups: 1, keep: 1, cleanup: 1, suggested: 2, unsafe: 1, correctCleanup: 1, edits: 1)
    let oneGroupCandidate = EvolutionScore(groups: 1, keep: 1, cleanup: 1, suggested: 1, unsafe: 0, correctCleanup: 1, edits: 0)
    precondition(oneGroupCandidate.improves(on: oneGroupBaseline))
    let unknown = [feedback(900), feedback(901)]
    var legacyMemory = ReviewMemory(); legacyMemory.feedback = unknown
    precondition(legacyMemory.latestFeedback.allSatisfy { $0.learningGroup == $0.assetID })
    let withMissing = all + [feedback(999, group: heldGroups.first, action: .keep)]
    failCandidate = false
    let partial = try await PreferenceLearner.evolve(initial, feedback: withMissing, model: "test", request: request,
        preview: { item in item.assetID == "private-asset-999" ? nil : Data("synthetic".utf8) })
    precondition(partial.active == 1 && partial.versions[0].candidate.edits == 0)
    let small = try await PreferenceLearner.evolve(initial, feedback: Array(train.prefix(1)) + Array(held.prefix(2)),
        model: "test", request: request, preview: preview)
    precondition(small.active == 1 && small.versions[0].baseline.groups == 1)
    // Exercise real evolution scheduling: two simultaneous previews and paired model requests, never more.
    var activeRequests = 0, peakRequests = 0, activePreviews = 0, peakPreviews = 0
    let parallel = try await PreferenceLearner.evolve(initial, feedback: all, model: "test", request: { content, instruction in
        if instruction.hasPrefix(ReviewProtocol.instruction) {
            activeRequests += 1; peakRequests = max(peakRequests, activeRequests)
            defer { activeRequests -= 1 }
            try await Task.sleep(for: .milliseconds(10))
            return try await request(content, instruction)
        }
        return try await request(content, instruction)
    }, preview: { _ in
        activePreviews += 1; peakPreviews = max(peakPreviews, activePreviews)
        defer { activePreviews -= 1 }
        try await Task.sleep(for: .milliseconds(5))
        return Data("synthetic-image".utf8)
    })
    precondition(parallel.active == 1 && peakRequests == 2 && peakPreviews == 2)
    precondition(parallel.versions[0].baseline.edits == evolved.versions[0].baseline.edits)
    precondition(parallel.versions[0].candidate.edits == evolved.versions[0].candidate.edits)
    var trainingCheckpoint = initial
    do {
        _ = try await PreferenceLearner.evolve(initial, feedback: all, model: "test", request: { content, instruction in
            if instruction.hasPrefix(ReviewProtocol.instruction) { throw Interrupted.stopped }
            return try await request(content, instruction)
        }, preview: preview, checkpoint: { trainingCheckpoint = $0 })
        fatalError("Injected replay failure was ignored")
    } catch Interrupted.stopped {}
    precondition(trainingCheckpoint.trainingDigest != nil && trainingCheckpoint.versions.isEmpty && trainingCheckpoint.active == nil)
    var retryCompression = 0
    _ = try await PreferenceLearner.evolve(trainingCheckpoint, feedback: all, model: "test", request: { content, instruction in
        if instruction == PreferenceLearner.compressionInstruction { retryCompression += 1 }
        return try await request(content, instruction)
    }, preview: preview)
    precondition(retryCompression == 0)
    return 43
}
