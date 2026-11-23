import AppKit
import Observation
import OSLog
import Photos
import SwiftUI

#if !REVIEW_CHECKS
@main
struct AlbumCleanupMacApp: App {
    @AppStorage(L10n.languageKey) private var appLanguage = "system"
    var body: some Scene {
        Window(tr("相册清理"), id: "library") {
            LibraryScreen()
                .frame(minWidth: 760, minHeight: 560)
                .tint(DesignTokens.accent)
                .environment(\.locale, L10n.locale(for: appLanguage))
        }
        .windowResizability(.contentMinSize)
    }
}
#endif

@MainActor
@Observable
final class PhotoLibraryModel {
    private(set) var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var photos: [PHAsset] = []
    private var accessibleAssets: [String: PHAsset] = [:]
    private(set) var isLoading = false
    private(set) var isAnalyzing = false
    private(set) var isDeleting = false
    private(set) var isLearning = false
    private(set) var learningRequestStartedAt: Date?
    private(set) var activeLearningRequests = 0
    private(set) var memory = ReviewMemory()
    private var storageError: String?
    private let storeURL: URL
    private var analysisTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.phi1220.albumcleanup.mac", category: "workflow")
    var status = tr("点击“分析全部”，模型自动处理明确的去留，只需审核不确定的照片。") {
        didSet { Self.logger.info("\(self.status, privacy: .public)") }
    }

    init() {
        storeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AlbumCleanup/review-memory.json")
        do { memory = try ReviewMemory.load(from: storeURL) }
        catch {
            storageError = tr("无法读取审核记录，已停止写入以保护原记录：%@", "\(error.localizedDescription)")
            status = storageError!
        }
    }

    var isBusy: Bool { isAnalyzing || isDeleting || isLearning }
    var reviews: [String: PhotoReview] { memory.reviews }
    var ownerDecisions: [String: PhotoDecision] { memory.decisions }
    var pendingDeletion: Set<String> { memory.queueIDs }
    var queuePhotos: [PHAsset] { sortedAssets(memory.queueIDs) }
    var uncertainPhotos: [PHAsset] { sortedAssets(memory.uncertainIDs) }
    var unprocessedPhotos: [PHAsset] { photos.filter { memory.reviews[$0.localIdentifier] == nil } }
    var feedbackCount: Int { memory.feedback.count }
    var canReadPhotos: Bool { authorization == .authorized || authorization == .limited }

    private func sortedAssets(_ ids: Set<String>) -> [PHAsset] {
        ids.compactMap { accessibleAssets[$0] }.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }

    private func commit(_ updated: ReviewMemory) throws {
        if let storageError { throw ReviewError.message(storageError) }
        do { try updated.save(to: storeURL) }
        catch { storageError = tr("保存审核记录失败：%@", "\(error.localizedDescription)"); throw error }
        memory = updated
    }

    func analyze(configuration: ModelConfiguration, assets: [PHAsset]) {
        guard !isBusy, !assets.isEmpty, assets.count <= ReviewProtocol.libraryLimit else { return }
        if let storageError { status = storageError; return }
        isAnalyzing = true
        analysisTask = Task { @MainActor in
            defer { isAnalyzing = false; analysisTask = nil; loadPhotos() }
            var completed = 0
            var failed = 0
            var lastError = ""
            do {
                let ranges = ReviewProtocol.batchRanges(for: assets.map {
                    ReviewProtocol.BatchMetadata(date: $0.creationDate, burstID: $0.burstIdentifier)
                })
                func progress() -> String {
                    tr("本次已完成 %@/%@ 张", "\(completed)", "\(assets.count)") + (failed > 0 ? tr("，未完成 %@ 张", "\(failed)") : "")
                }
                status = tr("本次 %@ 张，共 %@ 批，最多同时处理 %@ 批…", "\(assets.count)", "\(ranges.count)", "\(ReviewProtocol.concurrentBatches)")
                try await ReviewProtocol.forEachBatch(count: ranges.count) { index in
                    let batch = Array(assets[ranges[index]])
                    let result = try await self.analyzeBatch(configuration: configuration, assets: batch,
                        number: index + 1, total: ranges.count, progress: progress)
                    completed += result.completed
                    failed += result.failed
                    if !result.error.isEmpty { lastError = result.error }
                    self.status = tr("%@；已结束第 %@/%@ 批。", "\(progress())", "\(index + 1)", "\(ranges.count)")
                }
                status = tr("完成 %@ 张：待删除 %@ 张，需你判断 %@ 张。", "\(completed)", "\(queuePhotos.count)", "\(uncertainPhotos.count)")
                    + (failed > 0 ? tr("另有 %@ 张未完成，可再次点击分析重试。%@", "\(failed)", "\(lastError)") : tr("其余自动保留。"))
            } catch {
                status = Task.isCancelled ? tr("已取消；已完成 %@ 张的结果已保存，可继续分析剩余照片。", "\(completed)") : tr("分析停止：%@", "\(error.localizedDescription)")
            }
        }
    }

    private func analyzeBatch(configuration: ModelConfiguration, assets: [PHAsset], number: Int, total: Int,
        progress: @escaping () -> String)
        async throws -> (completed: Int, failed: Int, error: String) {
        let started = ContinuousClock.now
        var prepared: [PHAsset] = []
        var content: [[String: Any]] = []
        var snapshots: [String: AssetSnapshot] = [:]
        for (index, asset) in assets.enumerated() {
            try Task.checkCancellation()
            status = tr("%@；第 %@/%@ 批准备 %@/%@ 张…", "\(progress())", "\(number)", "\(total)", "\(index + 1)", "\(assets.count)")
            let image: NSImage
            do {
                image = try await PhotoImages.preview(asset, size: 768) { value in
                    self.status = tr("%@；第 %@/%@ 批第 %@ 张，iCloud 下载 %@%%…", "\(progress())", "\(number)", "\(total)", "\(index + 1)", "\(Int(value * 100))")
                }
            } catch {
                try Task.checkCancellation()
                status = tr("第 %@ 批第 %@ 张未能读取：%@；保留待重试。", "\(number)", "\(index + 1)", "\(error.localizedDescription)")
                continue
            }
            let data = try PhotoImages.jpeg(image)
            prepared.append(asset)
            snapshots[asset.localIdentifier] = AssetSnapshot(asset)
            content.append(["type": "text", "text": "编号 \(prepared.count)，拍摄时间 \(asset.creationDate?.formatted(.iso8601) ?? "未知")，\(asset.pixelWidth)×\(asset.pixelHeight)，收藏：\(asset.isFavorite)"])
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(data.base64EncodedString())"]])
        }
        try Task.checkCancellation()
        guard !prepared.isEmpty else { return (0, assets.count, "") }
        let requestStarted = ContinuousClock.now
        Self.logger.info("第 \(number) 批准备 \(prepared.count) 张耗时 \(String(describing: started.duration(to: requestStarted)), privacy: .public)")
        do {
            status = tr("%@；第 %@/%@ 批 %@ 张正在上传和分析…", "\(progress())", "\(number)", "\(total)", "\(prepared.count)")
            let response = try await VisionModel.request(configuration: configuration, content: content,
                instruction: ReviewProtocol.instruction + memory.preferencePrompt
                    + (memory.learning?.guidance(for: memory.latestFeedback, model: configuration.learningIdentity) ?? ""))
            try Task.checkCancellation()
            let advice = try ReviewProtocol.parse(Data(response.utf8), allowedIDs: Set(prepared.indices.map { String($0 + 1) }))
            let fresh = PHAsset.fetchAssets(withLocalIdentifiers: prepared.map(\.localIdentifier), options: nil)
            var current: [String: AssetSnapshot] = [:]
            fresh.enumerateObjects { asset, _, _ in current[asset.localIdentifier] = AssetSnapshot(asset) }
            guard current == snapshots else { throw ReviewError.message(tr("分析期间照片或授权发生变化，请刷新重试。")) }
            // Merge into the latest memory: another batch may have finished during the request.
            var updated = memory
            for item in advice {
                let asset = prepared[Int(item.id)! - 1]
                updated.reviews[asset.localIdentifier] = PhotoReview(snapshot: snapshots[asset.localIdentifier]!, advice: item,
                    keeperAssetID: item.keepID.map { prepared[Int($0)! - 1].localIdentifier }, model: configuration.model, analyzedAt: Date())
            }
            try commit(updated)
            Self.logger.info("第 \(number) 批模型及保存耗时 \(String(describing: requestStarted.duration(to: .now)), privacy: .public)")
            return (prepared.count, assets.count - prepared.count, "")
        } catch {
            try Task.checkCancellation()
            status = tr("第 %@ 批未完成：%@", "\(number)", "\(error.localizedDescription)")
            if case ReviewError.serviceStatus(let code) = error, [401, 403, 404, 429].contains(code) { throw error }
            if storageError != nil { throw error }
            return (0, assets.count, error.localizedDescription)
        }
    }

    func cancelAnalysis() { analysisTask?.cancel() }

    @discardableResult
    func decide(_ ids: Set<String>, decision: PhotoDecision, reason: String = "") -> Bool {
        guard !isBusy else { return false }
        do {
            var updated = memory
            try updated.record(ids, action: decision, reason: reason)
            try commit(updated)
            status = decision == .keep ? tr("已保留/复活 %@ 张，反馈已记入偏好 v%@。", "\(ids.count)", "\(memory.preferenceVersion)") : tr("已加入待删除图库，反馈已记入偏好 v%@。", "\(memory.preferenceVersion)")
            loadPhotos()
            return true
        } catch { status = error.localizedDescription; return false }
    }

    func deleteReviewed(_ ids: Set<String>, reason: String = "") {
        guard !isBusy else { return }
        do {
            if let storageError { throw ReviewError.message(storageError) }
            guard canReadPhotos, ids.isSubset(of: pendingDeletion) else { throw ReviewError.message(tr("权限或待删除范围已变化，请刷新。")) }
            let relevantIDs = Set(reviews.keys).union(reviews.values.compactMap(\.keeperAssetID))
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(relevantIDs), options: nil)
            var current: [String: AssetSnapshot] = [:]
            var assets: [PHAsset] = []
            fetched.enumerateObjects { asset, _, _ in
                current[asset.localIdentifier] = AssetSnapshot(asset)
                if ids.contains(asset.localIdentifier) { assets.append(asset) }
            }
            try ReviewProtocol.validateDeletion(ids, reviews: reviews, current: current)
            guard assets.allSatisfy({ $0.canPerform(.delete) }) else { throw ReviewError.message(tr("部分照片不支持删除，请检查图库。")) }
            try memory.save(to: storeURL)
            isDeleting = true
            status = tr("正在请求系统删除 %@ 张照片…", "\(assets.count)")
            PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.deleteAssets(assets as NSArray) }) { success, error in
                Task { @MainActor in
                    self.isDeleting = false
                    if success {
                        var updated = self.memory
                        do { try updated.record(ids, action: .cleanup, reason: reason) }
                        catch { self.status = tr("系统删除已完成，但生成反馈失败：%@", "\(error.localizedDescription)"); return }
                        for id in ids { updated.reviews.removeValue(forKey: id); updated.decisions.removeValue(forKey: id) }
                        do { try self.commit(updated) }
                        catch { self.status = tr("系统删除已完成，但保存记录失败：%@", "\(error.localizedDescription)"); return }
                        self.loadPhotos()
                        self.status = tr("已删除 %@ 张，可在系统“照片”的“最近删除”中恢复。", "\(ids.count)")
                    } else { self.status = tr("删除未完成：%@。待删除记录已保留。", "\(error?.localizedDescription ?? tr("系统取消"))") }
                }
            }
        } catch { status = error.localizedDescription }
    }

    private func updateLearning(configuration: ModelConfiguration) async throws {
        let feedback = memory.latestFeedback
        guard !feedback.isEmpty else { return }
        status = tr("正在将全部有效反馈压缩为长期偏好…")
        var state = memory.learning ?? PreferenceLearning()
        let request: PreferenceLearner.Request = { content, instruction in
            let started = ContinuousClock.now
            if self.activeLearningRequests == 0 { self.learningRequestStartedAt = Date() }
            self.activeLearningRequests += 1
            defer {
                self.activeLearningRequests -= 1
                if self.activeLearningRequests == 0 { self.learningRequestStartedAt = nil }
            }
            let result = try await VisionModel.request(configuration: configuration, content: content, instruction: instruction)
            Self.logger.info("自进化模型请求完成，响应字符 \(result.count)，耗时 \(String(describing: started.duration(to: .now)), privacy: .public)")
            return result
        }
        state.digest = try await PreferenceLearner.compact(state.digest, feedback: feedback, request: request,
            progress: { self.status = $0 }, checkpoint: { digest in
                var updated = self.memory
                var learning = updated.learning ?? PreferenceLearning()
                learning.digest = digest
                updated.learning = learning
                try self.commit(updated)
            })
        var updated = memory
        updated.learning = state
        try commit(updated)
        status = tr("长期偏好已保存；正在检查并回放评估进化候选，可取消…")
        do {
            state = try await PreferenceLearner.evolve(state, feedback: feedback,
                model: configuration.learningIdentity, request: request) { item in
                    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [item.assetID], options: nil)
                    guard let asset = assets.firstObject, AssetSnapshot(asset) == item.snapshot else { return nil }
                    let image: NSImage
                    do {
                        image = try await PhotoImages.preview(asset, size: 768) { value in
                            self.status = tr("自进化验证照片：iCloud 下载 %@%%…", "\(Int(value * 100))")
                        }
                    } catch {
                        try Task.checkCancellation()
                        return nil
                    }
                    let fresh = PHAsset.fetchAssets(withLocalIdentifiers: [item.assetID], options: nil).firstObject
                    guard fresh.map({ AssetSnapshot($0) == item.snapshot }) == true else { return nil }
                    return try PhotoImages.jpeg(image)
                } progress: { self.status = $0 } checkpoint: { learning in
                    var updated = self.memory
                    updated.learning = learning
                    try self.commit(updated)
                }
        } catch {
            try Task.checkCancellation()
            state = memory.learning ?? state
            state.status = tr("进化未完成：%@；长期偏好已保存，现有策略不变，可重试。", "\(error.localizedDescription)")
        }
        try Task.checkCancellation()
        updated = memory; updated.learning = state
        try commit(updated)
    }

    func refreshLearning() {
        guard !isBusy else { return }
        do {
            let configuration = try ModelConfiguration.load()
            try configuration.validate()
            isLearning = true
            analysisTask = Task { @MainActor in
                defer { isLearning = false; analysisTask = nil }
                do {
                    try await updateLearning(configuration: configuration)
                    status = L10n.storedStatus(memory.learning?.status ?? tr("还没有可归纳的用户反馈。"))
                } catch {
                    status = Task.isCancelled ? tr("已取消学习；已保存的长期记忆仍保留。") : tr("偏好更新失败：%@", "\(error.localizedDescription)")
                }
            }
        } catch { status = error.localizedDescription }
    }

    func rollbackLearning() {
        guard !isBusy else { return }
        do {
            var updated = memory
            updated.learning?.rollback()
            try commit(updated)
            status = L10n.storedStatus(updated.learning?.status ?? tr("当前使用基础策略。"))
        } catch { status = error.localizedDescription }
    }

    func clearFeedback() {
        guard !isBusy else { return }
        do {
            var updated = memory
            updated.feedback = []; updated.learning = nil; updated.preferenceVersion += 1
            try commit(updated)
            status = tr("已清空偏好反馈，现有去留结果仍保留。")
        } catch { status = error.localizedDescription }
    }

    func refreshAuthorization() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if canReadPhotos { loadPhotos() }
        else { cancelAnalysis(); photos = []; accessibleAssets = [:] }
    }

    func requestAccess() {
        isLoading = true
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
            Task { @MainActor in self?.isLoading = false; self?.refreshAuthorization() }
        }
    }
    func reload() { guard canReadPhotos, !isBusy else { return }; loadPhotos() }

    private func loadPhotos() {
        guard !isBusy else { return }
        isLoading = true
        defer { isLoading = false }
        accessibleAssets = [:]
        let savedIDs = Set(reviews.keys).union(memory.roundIDs ?? [])
        let saved = PHAsset.fetchAssets(withLocalIdentifiers: Array(savedIDs), options: nil)
        saved.enumerateObjects { asset, _, _ in self.accessibleAssets[asset.localIdentifier] = asset }
        var updated = memory
        updated.reviews = reviews.filter { id, review in accessibleAssets[id].map(AssetSnapshot.init) == review.snapshot }
        // If a referenced keeper disappears, require a fresh analysis instead of deleting its siblings.
        updated.reviews = updated.reviews.filter { _, review in review.keeperAssetID.map { updated.reviews[$0] != nil } ?? true }
        updated.decisions = updated.decisions.filter { updated.reviews[$0.key] != nil }
        if updated.reviews.count != reviews.count {
            do { try commit(updated); status = tr("照片或授权变化，失效建议已移除；可分析未处理的照片。") }
            catch { status = tr("保存记录失败：%@", "\(error.localizedDescription)") }
        }

        // Keep unfinished assets, then top up from all accessible unanalyzed images.
        // Uncertain advice has its own tab and never blocks loading more photos.
        let currentRound = memory.roundIDs?.filter { accessibleAssets[$0] != nil } ?? []
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        let orderedIDs = (0..<result.count).lazy.map { result.object(at: $0).localIdentifier }
        let nextIDs = memory.nextRound(from: orderedIDs, retaining: currentRound)
        let nextAssets = PHAsset.fetchAssets(withLocalIdentifiers: nextIDs, options: nil)
        nextAssets.enumerateObjects { asset, _, _ in self.accessibleAssets[asset.localIdentifier] = asset }
        if memory.roundIDs != nextIDs {
            var updated = memory
            updated.roundIDs = nextIDs
            do { try commit(updated) }
            catch { status = tr("保存待分析照片失败：%@", "\(error.localizedDescription)"); return }
            status += nextIDs.isEmpty ? tr(" 全部可访问照片已分析完成。")
                : tr(" 已载入 %@ 张待分析照片%@。", "\(nextIDs.count)", "\(nextIDs.count < ReviewProtocol.libraryLimit ? tr("，当前可访问的未分析照片不足 100 张") : "")")
        }
        photos = nextIDs.compactMap { accessibleAssets[$0] }
    }
}

struct LibraryScreen: View {
    @AppStorage(L10n.languageKey) private var appLanguage = "system"
    @State private var library = PhotoLibraryModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showPreferences = false
    @State private var reviewSession: ReviewSession?
    @State private var tab = LibraryTab.library
    @State private var restoreSelection: Set<String> = []
    @State private var showRestore = false
    @State private var restoreReason = ""
    @State private var deleteReason = ""

    enum LibraryTab: String, CaseIterable {
        case library, uncertain, queue
        var label: String {
            switch self {
            case .library: tr("图库")
            case .uncertain: tr("需你判断")
            case .queue: tr("待删除图库")
            }
        }
    }
    private struct ReviewSession: Identifiable { let id = UUID(); let assets: [PHAsset] }
    private var visiblePhotos: [PHAsset] {
        switch tab {
        case .library: library.unprocessedPhotos
        case .uncertain: library.uncertainPhotos
        case .queue: library.queuePhotos
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if library.canReadPhotos { photoContents } else { permissionState }
        }
        .background(DesignTokens.canvas)
        .navigationTitle(tr("相册清理"))
        .environment(\.locale, L10n.locale(for: appLanguage))
        .onChange(of: appLanguage) { _, _ in
            if !library.isBusy { library.status = L10n.storedStatus(library.status) }
        }
        .task { library.refreshAuthorization() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { library.refreshAuthorization() } }
        .onChange(of: library.isAnalyzing) { wasAnalyzing, analyzing in
            if wasAnalyzing && !analyzing && !library.uncertainPhotos.isEmpty {
                reviewSession = ReviewSession(assets: library.uncertainPhotos)
            }
        }
        .onChange(of: library.pendingDeletion) { _, ids in restoreSelection.formIntersection(ids) }
        .sheet(isPresented: $showSettings) { ModelSettingsSheet() }
        .sheet(isPresented: $showPreferences) { PreferenceHistorySheet(library: library) }
        .sheet(item: $reviewSession) { session in
            PhotoReviewSheet(assets: session.assets, library: library)
        }
        .sheet(isPresented: $showRestore) {
            VStack(alignment: .leading, spacing: 18) {
                Text(tr("复活 %@ 张照片", "\(restoreSelection.count)")).font(.title2.bold())
                Text(tr("这些照片会移回保留图库。你的选择和可选理由会记入后续模型提示。"))
                TextField(tr("理由（选填）"), text: $restoreReason, axis: .vertical).lineLimit(2...4)
                HStack {
                    Button(tr("取消")) { showRestore = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(tr("复活并记住反馈")) {
                        if library.decide(restoreSelection, decision: .keep, reason: restoreReason) {
                            restoreSelection = []; restoreReason = ""; showRestore = false
                        }
                    }.buttonStyle(.borderedProminent).tint(DesignTokens.keep)
                }
                Text(library.status).font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(width: 540).interactiveDismissDisabled()
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("相册清理 / 本轮待分析 %@ 张", "\(library.unprocessedPhotos.count)")).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(tab.label).font(.system(size: 28, weight: .semibold))
            }
            Spacer()
            Button(tr("刷新")) { library.reload() }.disabled(library.isBusy).keyboardShortcut("r", modifiers: .command)
            Button(tr("偏好记录（%@）", "\(library.feedbackCount)")) { showPreferences = true }.disabled(library.isBusy)
            Button(tr("模型设置")) { showSettings = true }.disabled(library.isBusy)
        }.padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 22)
    }

    private var photoContents: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if library.isBusy { ProgressView().controlSize(.small) }
                Text(library.status).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                if library.isAnalyzing || library.isLearning {
                    Button(library.isLearning ? tr("取消学习") : tr("取消分析")) { library.cancelAnalysis() }
                }
            }.padding(.horizontal, 32).padding(.vertical, 14).background(DesignTokens.surface)
            VStack(spacing: 14) {
                Picker(tr("照片分区"), selection: $tab) {
                    Text(tr("图库")).tag(LibraryTab.library)
                    Text(tr("需你判断（%@）", "\(library.uncertainPhotos.count)")).tag(LibraryTab.uncertain)
                    Text(tr("待删除图库（%@）", "\(library.queuePhotos.count)")).tag(LibraryTab.queue)
                }.pickerStyle(.segmented)
                HStack(spacing: 12) {
                    if tab == .queue {
                        Button(tr("复活所选（%@）", "\(restoreSelection.count)")) { restoreReason = ""; showRestore = true }
                            .buttonStyle(.borderedProminent).tint(DesignTokens.keep)
                            .disabled(restoreSelection.isEmpty || library.isBusy)
                        Spacer()
                        Button(tr("全部删除（%@）", "\(library.queuePhotos.count)"), role: .destructive) {
                            library.deleteReviewed(Set(library.queuePhotos.map(\.localIdentifier)), reason: deleteReason)
                        }.buttonStyle(.borderedProminent).tint(DesignTokens.delete)
                            .disabled(library.queuePhotos.isEmpty || library.isBusy)
                    } else {
                        Button(tr("分析全部（%@）", "\(library.unprocessedPhotos.count)")) { prepareAnalysis() }
                            .buttonStyle(.borderedProminent).disabled(library.unprocessedPhotos.isEmpty || library.isBusy)
                        Text(tr("明确去留由模型处理")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(tr("审核不确定项（%@）", "\(library.uncertainPhotos.count)")) {
                            reviewSession = ReviewSession(assets: library.uncertainPhotos)
                        }.disabled(library.uncertainPhotos.isEmpty || library.isBusy)
                    }
                }
                if tab == .queue {
                    TextField(tr("删除理由（选填，也会记录为反馈）"), text: $deleteReason).textFieldStyle(.roundedBorder)
                    Text(tr("这些照片仍在系统图库中。全部删除会同步至 iCloud 设备，并进入系统“最近删除”；复活只移出当前待删除队列。"))
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(tr("云端照片会按需从 iCloud 下载。点击分析全部会将 768 像素预览及已保存反馈发送至你配置的视觉模型。"))
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.horizontal, 32).padding(.vertical, 16)

            if library.isLoading { Spacer(); ProgressView(tr("正在读取图库…")); Spacer() }
            else if visiblePhotos.isEmpty {
                ContentUnavailableView(tab == .queue ? tr("没有待删除照片") : tab == .uncertain ? tr("没有需要你判断的照片") : tr("没有可显示的照片"),
                    systemImage: "photo.on.rectangle.angled", description: Text(tab == .uncertain ? tr("明确的去留已由模型处理。") : tr("分析结果会自动归入对应分区。")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 176), spacing: 18)], spacing: 22) {
                        ForEach(Array(visiblePhotos.enumerated()), id: \.element.localIdentifier) { index, asset in
                            VStack(alignment: .leading, spacing: 10) {
                                PhotoCard(asset: asset, index: index + 1, disabled: library.isBusy) {
                                    reviewSession = ReviewSession(assets: [asset])
                                }
                                if tab == .queue {
                                    Toggle(tr("选中复活"), isOn: Binding(
                                        get: { restoreSelection.contains(asset.localIdentifier) },
                                        set: { selected in
                                            if selected { restoreSelection.insert(asset.localIdentifier) }
                                            else { restoreSelection.remove(asset.localIdentifier) }
                                        }
                                    )).disabled(library.isBusy)
                                }
                                Text(decisionLabel(asset.localIdentifier)).font(.callout.weight(.medium))
                                if let review = library.reviews[asset.localIdentifier] {
                                    Text(review.advice.reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    Button(tr("查看 / 修改决定")) { reviewSession = ReviewSession(assets: [asset]) }.disabled(library.isBusy)
                                }
                            }
                        }
                    }.padding(32).frame(maxWidth: 1280).frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func decisionLabel(_ id: String) -> String {
        if library.pendingDeletion.contains(id) { return tr("待删除") }
        switch library.memory.decision(for: id) {
        case .keep: return library.ownerDecisions[id] == .keep ? tr("你已保留") : tr("模型已保留")
        case .uncertain: return tr("需要你判断")
        case .cleanup: return tr("对比保留项，暂不删除")
        case nil: return tr("尚未分析")
        }
    }

    private var permissionState: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 34)).foregroundStyle(DesignTokens.accent)
            Text(tr("连接你的照片图库")).font(.title2.bold())
            Text(tr("读取最近 100 张照片，模型处理明确去留，你只需判断不确定项。最终删除由你在待删除图库中执行。"))
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 400)
            if library.authorization == .notDetermined {
                Button(tr("允许访问照片")) { library.requestAccess() }.buttonStyle(.borderedProminent).disabled(library.isLoading)
            } else {
                Button(tr("打开照片权限设置")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") { NSWorkspace.shared.open(url) }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32)
    }

    private func prepareAnalysis() {
        do {
            let configuration = try ModelConfiguration.load()
            try configuration.validate()
            library.analyze(configuration: configuration, assets: library.unprocessedPhotos)
        } catch { library.status = error.localizedDescription; showSettings = true }
    }
}

struct PhotoCard: View {
    @AppStorage(L10n.languageKey) private var appLanguage = "system"
    let asset: PHAsset
    let index: Int
    @State private var image: NSImage?
    let disabled: Bool
    let open: () -> Void
    @State private var loading = true
    @State private var downloadProgress: Double?
    @State private var loadError: String?
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: open) { card }.buttonStyle(.plain).disabled(disabled)
                .accessibilityLabel(accessibilityDescription).help(tr("查看照片和理由"))
            if loadError != nil {
                Button(tr("重试读取照片")) { attempt += 1 }.disabled(disabled)
            }
        }
        .environment(\.locale, L10n.locale(for: appLanguage))
        .task(id: attempt) {
            let currentAttempt = attempt
            loading = true; loadError = nil; downloadProgress = nil
            do {
                let result = try await PhotoImages.preview(asset, size: 440) { value in
                    if loading && attempt == currentAttempt { downloadProgress = value }
                }
                guard !Task.isCancelled else { return }
                image = result
            } catch {
                guard !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
            loading = false
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topTrailing) {
                Rectangle()
                    .fill(DesignTokens.thumbnailBackground)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            VStack(spacing: 10) {
                                if loading {
                                    if let downloadProgress {
                                        ProgressView(value: downloadProgress)
                                        Text(tr("iCloud 下载 %@%%", "\(Int(downloadProgress * 100))")).font(.caption)
                                    } else { ProgressView(tr("正在读取…")).controlSize(.small) }
                                } else {
                                    Image(systemName: "icloud.slash").font(.system(size: 25, weight: .light))
                                    Text(tr("读取失败，请重试")).font(.caption).multilineTextAlignment(.center).help(loadError ?? tr("照片暂不可用"))
                                }
                            }.foregroundStyle(DesignTokens.secondaryText).padding(16)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: DesignTokens.cardRadius)
                            .strokeBorder(DesignTokens.separator.opacity(0.55), lineWidth: 1)
                    }

                Text(String(format: "%02d", index))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(8)
            }
            .clipped()

            HStack(alignment: .top, spacing: 8) {
                Capsule()
                    .fill(DesignTokens.marker)
                    .frame(width: 3, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(dateLabel)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(DesignTokens.primaryText)
                    Text("\(asset.pixelWidth) × \(asset.pixelHeight)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DesignTokens.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
        }
        .accessibilityElement(children: .combine)
    }

    private var accessibilityDescription: String {
        let details = tr("照片 %@，%@，%@ 乘 %@ 像素", "\(index)", "\(dateLabel)", "\(asset.pixelWidth)", "\(asset.pixelHeight)")
        if let downloadProgress, loading { return tr("%@，iCloud 下载 %@%%", "\(details)", "\(Int(downloadProgress * 100))") }
        if let loadError { return tr("%@，读取失败：%@", "\(details)", "\(loadError)") }
        return details
    }

    private var dateLabel: String {
        asset.creationDate?.formatted(.dateTime.year().month(.abbreviated).day().locale(L10n.locale())) ?? tr("拍摄时间未知")
    }


}

enum DesignTokens {
    static let accent = Color(red: 0.22, green: 0.35, blue: 0.72)
    static let marker = Color(red: 0.73, green: 0.49, blue: 0.16)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let thumbnailBackground = Color(nsColor: .underPageBackgroundColor)
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let separator = Color(nsColor: .separatorColor)
    static let cardRadius: CGFloat = 12
    static let keep = Color(red: 27 / 255.0, green: 110 / 255.0, blue: 56 / 255.0)
    static let delete = Color(red: 184 / 255.0, green: 31 / 255.0, blue: 26 / 255.0)
}
