import Foundation
import AppKit
import ImageIO
import Photos

@main
struct ReviewChecks {
    @MainActor static func main() async throws {
        var checks = try await checkPreferenceLearning()
        func rejects(_ name: String, _ operation: () throws -> Void) {
            do { try operation(); fatalError("Unexpected acceptance: \(name)") }
            catch { checks += 1 }
        }
        // JSON Object mode rejects prompts without the literal JSON keyword (HTTP 400).
        // Test the actual shared HTTP request used by compression and candidate generation.
        let requestSettings = ModelConfiguration(baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            model: "test", apiKey: "synthetic-key")
        for instruction in [PreferenceLearner.compressionInstruction, "根据学习反馈提出审核补充，只返回 {\"guidance\":\"…\"}。"] {
            let request = try VisionModel.makeRequest(configuration: requestSettings,
                content: [["type": "text", "text": "程序生成的测试反馈"]], instruction: instruction)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let system = messages[0]["content"] as! String
            precondition(system.hasPrefix(instruction) && system.lowercased().contains("json"))
            precondition((body["response_format"] as! [String: String])["type"] == "json_object")
            precondition(body["enable_thinking"] as? Bool == false)
            checks += 1
        }
        for (base, expected) in [
            ("https://example.com", "https://example.com/chat/completions"),
            ("https://example.com/", "https://example.com/chat/completions"),
            ("https://example.com/v1/", "https://example.com/v1/chat/completions"),
            (" https://example.com/v1/chat/completions ", "https://example.com/v1/chat/completions")
        ] {
            let endpoint = try ReviewProtocol.endpoint(base)
            precondition(endpoint.absoluteString == expected)
            checks += 1
        }
        for bad in ["http://example.com/v1", "https://key@example.com", "https://example.com?key=secret", "file:///tmp", "https://example.com/#secret"] {
            rejects("unsafe endpoint") { _ = try ReviewProtocol.endpoint(bad) }
        }
        let valid = Data(#"{"photos":[{"id":"1","decision":"keep","reason":"主体完整"},{"id":"2","decision":"cleanup","reason":"与 1 重复","keep_id":"1"}]}"#.utf8)
        let advice = try ReviewProtocol.parse(valid, allowedIDs: ["1", "2"])
        precondition(advice.count == 2 && advice[1].keepID == "1"); checks += 1
        for bad in [
            #"{"photos":[{"id":"1","decision":"keep","reason":"ok"}]}"#,
            #"{"photos":[{"id":"1","decision":"keep","reason":"ok"},{"id":"1","decision":"cleanup","reason":"ok"}]}"#,
            #"{"photos":[{"id":"1","decision":"keep","reason":"ok"},{"id":"99","decision":"cleanup","reason":"ok"}]}"#,
            #"{"photos":[{"id":"1","decision":"keep","reason":"ok"},{"id":"2","decision":"delete","reason":"ok"}]}"#,
            #"{"photos":[{"id":"1","decision":"keep","reason":"ok"},{"id":"2","decision":"cleanup","reason":"  "}]}"#,
            #"{"photos":[{"id":"1","decision":"keep","reason":"ok"},{"id":"2","decision":"cleanup","reason":"ok","keep_id":"2"}]}"#,
            #"{"photos":[{"id":"1","decision":"cleanup","reason":"ok","keep_id":"2"},{"id":"2","decision":"cleanup","reason":"ok","keep_id":"1"}]}"#
        ] {
            rejects("invalid model response") { _ = try ReviewProtocol.parse(Data(bad.utf8), allowedIDs: ["1", "2"]) }
        }
        rejects("empty batch") { _ = try ReviewProtocol.parse(Data(#"{"photos":[]}"#.utf8), allowedIDs: []) }
        let snapshot = AssetSnapshot(modified: Date(timeIntervalSince1970: 10), width: 100, height: 200, favorite: false)
        let reviews = [
            "assetA": PhotoReview(snapshot: snapshot, advice: advice[0], keeperAssetID: nil, model: "test", analyzedAt: Date()),
            "assetB": PhotoReview(snapshot: snapshot, advice: advice[1], keeperAssetID: "assetA", model: "test", analyzedAt: Date())
        ]
        let current = ["assetA": snapshot, "assetB": snapshot]
        try ReviewProtocol.validateDeletion(["assetB"], reviews: reviews, current: current); checks += 1
        rejects("keeper must survive") { try ReviewProtocol.validateDeletion(["assetA", "assetB"], reviews: reviews, current: current) }
        rejects("unreviewed asset") { try ReviewProtocol.validateDeletion(["assetC"], reviews: reviews, current: current) }
        rejects("missing keeper") { try ReviewProtocol.validateDeletion(["assetB"], reviews: reviews, current: ["assetB": snapshot]) }
        rejects("edited photo") {
            let edited = AssetSnapshot(modified: Date(), width: 100, height: 200, favorite: false)
            try ReviewProtocol.validateDeletion(["assetB"], reviews: reviews, current: ["assetA": snapshot, "assetB": edited])
        }
        rejects("empty deletion") { try ReviewProtocol.validateDeletion([], reviews: reviews, current: current) }
        let image = NSImage(size: NSSize(width: 2000, height: 1000), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        checks += try await checkCloudImageLoading(image)
        let jpeg = try PhotoImages.jpeg(image)
        let decoded = NSBitmapImageRep(data: jpeg)!
        precondition(decoded.pixelsWide == 768 && decoded.pixelsHigh == 384)
        let source = CGImageSourceCreateWithData(jpeg as CFData, nil)!
        let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        precondition(metadata[kCGImagePropertyGPSDictionary] == nil)
        checks += 1
        var highConfidence = advice[1]
        highConfidence.confidence = 0.95
        precondition(ReviewProtocol.automaticDecision(highConfidence, snapshot: snapshot) == .cleanup)
        precondition(ReviewProtocol.automaticDecision(advice[1], snapshot: snapshot) == .uncertain)
        let favorite = AssetSnapshot(modified: snapshot.modified, width: 100, height: 200, favorite: true)
        precondition(ReviewProtocol.automaticDecision(highConfidence, snapshot: favorite) == .keep)
        checks += 3
        rejects("invalid confidence") {
            _ = try ReviewProtocol.parse(Data(#"{"photos":[{"id":"1","decision":"cleanup","reason":"test","confidence":2}]}"#.utf8), allowedIDs: ["1"])
        }
        let confidentJSON = Data(#"{"photos":[{"id":"1","decision":"cleanup","reason":"empty test image","confidence":0.95}]}"#.utf8)
        let decodedAdvice = try ReviewProtocol.parse(confidentJSON, allowedIDs: ["1"])[0]
        precondition(decodedAdvice.confidence == 0.95); checks += 1
        var memory = ReviewMemory()
        let record = PhotoReview(snapshot: snapshot, advice: decodedAdvice, keeperAssetID: nil, model: "test", analyzedAt: Date())
        memory.reviews = Dictionary(uniqueKeysWithValues: (0..<100).map { ("local-secret-\($0)", record) })
        let ids = Set(memory.reviews.keys)
        precondition(memory.queueIDs.count == 100 && memory.feedback.isEmpty && memory.preferenceVersion == 0)
        let orderedIDs = (0..<250).map { "local-secret-\($0)" }
        precondition(memory.nextRound(from: orderedIDs) == Array(orderedIDs[100..<200]))
        var unsure = record.advice
        unsure.confidence = nil
        var rounds = memory
        rounds.reviews["local-secret-99"] = PhotoReview(snapshot: snapshot, advice: unsure,
            keeperAssetID: nil, model: "test", analyzedAt: Date())
        precondition(rounds.nextRound(from: orderedIDs, retaining: ["local-secret-99"]) == Array(orderedIDs[100..<200]))
        try rounds.record(["local-secret-99"], action: .keep, reason: "")
        precondition(rounds.nextRound(from: orderedIDs, limit: 100) == Array(orderedIDs[100..<200]))
        precondition(memory.nextRound(from: orderedIDs.prefix(130)) == Array(orderedIDs[100..<130]))
        precondition(memory.nextRound(from: orderedIDs.prefix(100)).isEmpty)
        let remaining = Array(orderedIDs[100..<119])
        let toppedUp = rounds.nextRound(from: orderedIDs, retaining: remaining + ["local-secret-0", "local-secret-99"])
        precondition(toppedUp == Array(orderedIDs[100..<200]))
        precondition(rounds.nextRound(from: orderedIDs.prefix(119), retaining: remaining) == remaining)
        precondition(rounds.nextRound(from: orderedIDs, retaining: Array(orderedIDs[220..<239])).count == 100)
        precondition(rounds.nextRound(from: orderedIDs, retaining: remaining + remaining).count == 100)
        memory.roundIDs = Array(orderedIDs[100..<200])
        checks += 8
        try ReviewProtocol.validateDeletion(ids, reviews: memory.reviews, current: Dictionary(uniqueKeysWithValues: ids.map { ($0, snapshot) }))
        checks += 2
        try memory.record(["local-secret-0"], action: .keep, reason: "temporary old preference")
        precondition(memory.queueIDs.count == 99 && memory.feedback.count == 1 && memory.preferenceVersion == 1)
        try memory.record(["local-secret-0"], action: .cleanup, reason: "corrected explicit preference")
        precondition(memory.queueIDs.count == 100 && memory.feedback.count == 2 && memory.preferenceVersion == 2)
        precondition(memory.preferencePrompt.contains("corrected explicit preference"))
        precondition(!memory.preferencePrompt.contains("temporary old preference") && !memory.preferencePrompt.contains("local-secret-0"))
        checks += 4
        try memory.record(["local-secret-0"], action: .cleanup, reason: "")
        precondition(memory.latestFeedback[0].reason == "corrected explicit preference")
        checks += 1
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.json")
        try memory.save(to: file)
        let restored = try ReviewMemory.load(from: file)
        precondition(restored.queueIDs == memory.queueIDs && restored.feedback.count == 3 && restored.preferencePrompt == memory.preferencePrompt)
        precondition(restored.roundIDs == memory.roundIDs)
        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(memory)) as! [String: Any]
        let legacyData = try JSONSerialization.data(withJSONObject: legacy.filter { $0.key != "roundIDs" })
        let migrated = try JSONDecoder().decode(ReviewMemory.self, from: legacyData)
        precondition(migrated.roundIDs == nil && migrated.queueIDs == memory.queueIDs)
        checks += 2
        checks += 1
        try Data("corrupt".utf8).write(to: file)
        rejects("corrupt records must not be discarded") { _ = try ReviewMemory.load(from: file) }
        var protectedMemory = ReviewMemory()
        protectedMemory.reviews = reviews
        rejects("human must preserve comparison keeper") { try protectedMemory.record(["assetA"], action: .cleanup, reason: "") }
        try protectedMemory.record(["assetB"], action: .keep, reason: "")
        precondition(protectedMemory.queueIDs.isEmpty && protectedMemory.feedback.last?.action == .keep)
        precondition(protectedMemory.latestFeedback[0].learningGroup == "assetA")
        checks += 1

        // Every round size, including retries and the final short round, is covered exactly once.
        let unknown = ReviewProtocol.BatchMetadata(date: nil, burstID: nil)
        for count in 0...ReviewProtocol.libraryLimit {
            let plan = ReviewProtocol.batchRanges(for: Array(repeating: unknown, count: count))
            precondition(plan.flatMap { Array($0) } == Array(0..<count))
            precondition(plan.allSatisfy { !$0.isEmpty && $0.count <= ReviewProtocol.batchLimit })
            precondition(plan.count <= 1 || plan.count.isMultiple(of: ReviewProtocol.concurrentBatches))
            if let smallest = plan.map(\.count).min(), let largest = plan.map(\.count).max() {
                precondition(largest - smallest <= 1)
            }
            checks += 1
        }
        let hundred = ReviewProtocol.batchRanges(for: Array(repeating: unknown, count: 100))
        precondition(hundred.count == 10 && hundred.allSatisfy { $0.count == 10 }); checks += 1
        let bursts = (0..<20).map { ReviewProtocol.BatchMetadata(date: nil, burstID: $0 < 8 ? "first" : "second") }
        precondition(ReviewProtocol.batchRanges(for: bursts) == [0..<8, 8..<20]); checks += 1
        let dates = (0..<20).map { index in
            ReviewProtocol.BatchMetadata(date: Date(timeIntervalSince1970: Double(index < 8 ? index : index + 1000)), burstID: nil)
        }
        precondition(ReviewProtocol.batchRanges(for: dates) == [0..<8, 8..<20]); checks += 1
        let longBurst = Array(repeating: ReviewProtocol.BatchMetadata(date: nil, burstID: "long"), count: 25)
        let splitBurst = ReviewProtocol.batchRanges(for: longBurst)
        precondition(splitBurst.flatMap { Array($0) } == Array(0..<25) && splitBurst.allSatisfy { $0.count <= 12 })
        checks += 1

        // Exercise the real 100-photo plan/scheduler without Photos access or paid model calls.
        var active = 0
        var peak = 0
        var finished: Set<Int> = []
        try await ReviewProtocol.forEachBatch(count: hundred.count) { index in
            active += 1; peak = max(peak, active)
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(index.isMultiple(of: 2) ? 20 : 5))
            precondition(finished.insert(index).inserted)
        }
        precondition(peak == 2 && active == 0 && finished == Set(hundred.indices)); checks += 1
        try await ReviewProtocol.forEachBatch(count: 0) { _ in fatalError("Empty run started work") }
        try await ReviewProtocol.forEachBatch(count: 1) { index in precondition(index == 0) }
        checks += 2

        enum BatchFailure: Error { case rejected }
        var started: Set<Int> = []
        var cancelled = 0
        do {
            try await ReviewProtocol.forEachBatch(count: 9) { index in
                started.insert(index)
                if index == 0 {
                    try await Task.sleep(for: .milliseconds(10))
                    throw BatchFailure.rejected
                }
                do { try await Task.sleep(for: .seconds(10)) }
                catch is CancellationError { cancelled += 1; throw CancellationError() }
            }
            fatalError("Batch failure was swallowed")
        } catch BatchFailure.rejected {}
        precondition(started == [0, 1] && cancelled == 1); checks += 1

        started = []; cancelled = 0
        let run = Task { @MainActor in
            try await ReviewProtocol.forEachBatch(count: 9) { index in
                started.insert(index)
                do { try await Task.sleep(for: .seconds(10)) }
                catch is CancellationError { cancelled += 1; throw CancellationError() }
            }
        }
        while started.count < 2 { await Task.yield() }
        run.cancel()
        do { try await run.value; fatalError("Cancellation was swallowed") }
        catch is CancellationError {}
        precondition(started == [0, 1] && cancelled == 2); checks += 1
        print("Passed \(checks) model/deletion boundary checks; no network or Photos changes performed.")
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--check-model" {
            let fallback = ModelConfiguration(baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen3-vl-flash", apiKey: "")
            let settings = try ModelConfiguration.importing(URL(fileURLWithPath: CommandLine.arguments[2]), fallback: fallback)
            let result = try await VisionModel.request(configuration: settings,
                content: [["type": "text", "text": "Return {\"ok\":true}"]], instruction: "Return JSON only.")
            struct Probe: Decodable { let ok: Bool }
            let probe = try JSONDecoder().decode(Probe.self, from: Data(result.utf8))
            precondition(probe.ok)
            print("Native model connection passed (text only; no photos sent or changed).")
        }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--check-learning" {
            let fallback = ModelConfiguration(baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen3-vl-flash", apiKey: "")
            let settings = try ModelConfiguration.importing(URL(fileURLWithPath: CommandLine.arguments[2]), fallback: fallback)
            let synthetic = (0..<119).map { index in
                OwnerFeedback(id: UUID(), assetID: "synthetic-\(index)", snapshot: snapshot, action: .keep,
                    reason: index < 107 ? "" : "程序生成的测试反馈：我想保留测试用的红色方块。",
                    modelObservation: "测试红色方块", date: Date())
            }
            let started = ContinuousClock.now
            var outputCharacters = 0
            let digest = try await PreferenceLearner.compact(PreferenceDigest(), feedback: synthetic) { content, instruction in
                let result = try await VisionModel.request(configuration: settings, content: content, instruction: instruction)
                outputCharacters += result.count
                return result
            }
            precondition(Set(digest.rules.flatMap(\.evidence)).union(digest.exampleIDs ?? []) == Set(synthetic.map(\.id)))
            precondition(digest.exampleIDs?.count == 107 && digest.rules.count < 12)
            print("Live compression passed: 119 synthetic sources, 107 cached locally, 12 explained sources merged into \(digest.rules.count) rules (\(outputCharacters) response characters); elapsed \(started.duration(to: .now)). No user data sent.")
        }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--check-vision" {
            let fallback = ModelConfiguration(baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen3-vl-flash", apiKey: "")
            let settings = try ModelConfiguration.importing(URL(fileURLWithPath: CommandLine.arguments[2]), fallback: fallback)
            let result = try await VisionModel.request(configuration: settings,
                content: [["type": "text", "text": "编号 1：程序生成的纯红测试图，非用户照片，收藏 false"],
                          ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]]],
                instruction: ReviewProtocol.instruction + ReviewMemory().preferencePrompt)
            let output = try ReviewProtocol.parse(Data(result.utf8), allowedIDs: ["1"])
            precondition(output[0].confidence != nil)
            print("Native vision schema passed using a generated image; no library photos read or changed.")
        }
    }
}

@MainActor
func checkCloudImageLoading(_ image: NSImage) async throws -> Int {
    var cancelled: [PHImageRequestID] = []
    var progress: [Double] = []
    let loaded = try await PhotoImages.load(progress: { progress.append($0) }, start: { options, reply in
        precondition(options.isNetworkAccessAllowed && options.deliveryMode == .highQualityFormat)
        reply(image, [PHImageResultIsDegradedKey: true]) // never accept a degraded substitute
        var stop: ObjCBool = false
        options.progressHandler?(0.5, nil, &stop, nil)
        Task { @MainActor in
            await Task.yield()
            reply(image, [PHImageResultIsDegradedKey: false])
            reply(nil, [PHImageCancelledKey: true]) // a late second callback must be harmless
        }
        return 101
    }, cancel: { cancelled.append($0) })
    precondition(loaded === image && cancelled == [101] && progress == [0.5])
    do {
        _ = try await PhotoImages.load(start: { _, reply in
            reply(nil, [PHImageResultIsInCloudKey: true]); return 102
        }, cancel: { cancelled.append($0) })
        fatalError("Missing cloud image was accepted")
    } catch { precondition(error.localizedDescription.contains("iCloud")) }
    precondition(cancelled.last == 102)
    do {
        _ = try await PhotoImages.load(start: { _, reply in
            reply(nil, [PHImageErrorKey: NSError(domain: "test.offline", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "synthetic offline error"])]); return 103
        }, cancel: { cancelled.append($0) })
        fatalError("Download error was ignored")
    } catch { precondition(error.localizedDescription == "synthetic offline error") }
    do {
        _ = try await PhotoImages.load(timeout: 0.01, start: { _, _ in 104 }, cancel: { cancelled.append($0) })
        fatalError("Image request did not time out")
    } catch { precondition(error.localizedDescription.contains("超时")) }
    precondition(cancelled.last == 104)
    var started = false
    var lateReply: PhotoImages.ImageReply?
    let run = Task { @MainActor in
        try await PhotoImages.load(start: { _, reply in
            started = true; lateReply = reply; return 105
        }, cancel: { cancelled.append($0) })
    }
    while !started { await Task.yield() }
    run.cancel()
    do { _ = try await run.value; fatalError("Cancelled image request succeeded") }
    catch is CancellationError {}
    lateReply?(image, nil)
    precondition(cancelled.filter { $0 == 105 }.count == 1)
    let beforeStart = Task { @MainActor in
        try await PhotoImages.load(start: { _, _ in fatalError("Pre-cancelled task started a download") }, cancel: { _ in })
    }
    beforeStart.cancel()
    do { _ = try await beforeStart.value; fatalError("Pre-cancelled task succeeded") }
    catch is CancellationError {}
    return 9
}
