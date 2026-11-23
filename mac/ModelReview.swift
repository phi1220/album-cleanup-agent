import AppKit
import Foundation
import Photos
import Security
import SwiftUI

struct ModelConfiguration {
    let baseURL: String
    let model: String
    let apiKey: String

    var learningIdentity: String { baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "|" + model }

    static func load() throws -> Self {
        let defaults = UserDefaults.standard
        return Self(
            baseURL: defaults.string(forKey: "modelBaseURL") ?? "https://dashscope.aliyuncs.com/compatible-mode/v1",
            model: defaults.string(forKey: "visionModel") ?? "qwen3-vl-flash",
            apiKey: try ModelKeychain.read()
        )
    }

    func validate() throws {
        _ = try ReviewProtocol.endpoint(baseURL)
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReviewError.message("请填写视觉模型名称和 API Key。")
        }
    }

    static func importing(_ url: URL, fallback: Self) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 < 65_536 else {
            throw ReviewError.message("配置文件过大，请选择项目的 .env 文件。")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
        var values: [String: String] = [:]
        let keys = Set(["QWEN_BASE_URL", "QWEN_MODEL", "QWEN_API_KEY", "DASHSCOPE_API_KEY"])
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            if keys.contains(key) {
                values[key] = parts[1].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        guard !values.isEmpty else { throw ReviewError.message("未找到 QWEN 模型配置，请选择正确的 .env 文件。") }
        return Self(baseURL: values["QWEN_BASE_URL"] ?? fallback.baseURL,
                    model: values["QWEN_MODEL"] ?? fallback.model,
                    apiKey: values["QWEN_API_KEY"].flatMap { $0.isEmpty ? nil : $0 } ?? values["DASHSCOPE_API_KEY"] ?? fallback.apiKey)
    }
}

enum ModelKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.phi1220.albumcleanup.mac",
         kSecAttrAccount as String: "vision-api-key"]
    }

    static func read() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw ReviewError.message("无法读取钥匙串中的 API Key（\(status)）。请检查钥匙串访问权限。")
        }
        return key
    }

    static func save(_ key: String) throws {
        let attributes = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw ReviewError.message("无法保存 API Key 到钥匙串（\(status)），设置未保存。")
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum VisionModel {
    private static let session: URLSession = {
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForResource = 150
        settings.httpShouldSetCookies = false
        settings.httpMaximumConnectionsPerHost = ReviewProtocol.concurrentBatches
        return URLSession(configuration: settings, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static func makeRequest(configuration: ModelConfiguration, content: [[String: Any]], instruction: String) throws -> URLRequest {
        try configuration.validate()
        let endpoint = try ReviewProtocol.endpoint(configuration.baseURL)
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": [["role": "system", "content": instruction + "\n请只返回一个 JSON 对象。"], ["role": "user", "content": content]],
            "response_format": ["type": "json_object"]
        ]
        if endpoint.host?.hasSuffix(".aliyuncs.com") == true || endpoint.host?.hasSuffix(".alibabacloud.com") == true {
            body["enable_thinking"] = false
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func request(configuration: ModelConfiguration, content: [[String: Any]], instruction: String) async throws -> String {
        let request = try makeRequest(configuration: configuration, content: content, instruction: instruction)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ReviewError.message("未收到模型服务响应。") }
        guard (200..<300).contains(response.statusCode) else {
            throw ReviewError.serviceStatus(response.statusCode)
        }
        struct Envelope: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]
        }
        guard data.count <= 2_000_000,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let choice = envelope.choices.first, choice.finish_reason != "length",
              let content = choice.message.content else {
            throw ReviewError.message("模型响应不完整或格式不兼容，请检查是否使用支持图片的 Chat Completions 模型。")
        }
        return content
    }
}

extension AssetSnapshot {
    init(_ asset: PHAsset) {
        self.init(modified: asset.modificationDate, width: asset.pixelWidth, height: asset.pixelHeight, favorite: asset.isFavorite)
    }
}

private final class PreviewRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NSImage, Error>?
    private var requestID: PHImageRequestID?
    private var result: Result<NSImage, Error>?
    private var timer: DispatchWorkItem?
    private let cancel: (PHImageRequestID) -> Void

    init(cancel: @escaping (PHImageRequestID) -> Void) { self.cancel = cancel }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return result != nil
    }
    func install(_ continuation: CheckedContinuation<NSImage, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return }
        self.continuation = continuation
        lock.unlock()
    }
    func setRequestID(_ id: PHImageRequestID) {
        lock.lock()
        requestID = id
        let finished = result != nil
        lock.unlock()
        if finished { cancel(id) }
    }
    func setTimer(_ timer: DispatchWorkItem) {
        lock.lock()
        if result != nil { lock.unlock(); timer.cancel(); return }
        self.timer = timer
        lock.unlock()
    }
    func finish(_ result: Result<NSImage, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation, timer = self.timer, id = requestID
        self.continuation = nil; self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(with: result)
        if let id { cancel(id) }
    }
}

enum PhotoImages {
    typealias ImageReply = (NSImage?, [AnyHashable: Any]?) -> Void

    @MainActor static func preview(_ asset: PHAsset, size: CGFloat,
        progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> NSImage {
        try await load(progress: progress, start: { options, reply in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: size, height: size),
                contentMode: .aspectFit, options: options, resultHandler: reply)
        }, cancel: { PHImageManager.default().cancelImageRequest($0) })
    }

    // The injected PhotoKit callbacks also exercise the real download/cancellation lifecycle in offline checks.
    @MainActor static func load(timeout: TimeInterval = 120,
        progress: @escaping @MainActor (Double) -> Void = { _ in },
        start: (PHImageRequestOptions, @escaping ImageReply) -> PHImageRequestID,
        cancel: @escaping (PHImageRequestID) -> Void) async throws -> NSImage {
        try Task.checkCancellation()
        let state = PreviewRequest(cancel: cancel)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                guard !state.isFinished else { return }
                let timer = DispatchWorkItem { [weak state] in
                    state?.finish(.failure(ReviewError.message("读取照片超时；请检查 iCloud 与网络后重试。")))
                }
                state.setTimer(timer)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: timer)
                let options = PHImageRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .exact
                options.isNetworkAccessAllowed = true
                options.progressHandler = { value, error, stop, _ in
                    if state.isFinished { stop.pointee = true; return }
                    if let error { state.finish(.failure(error)); return }
                    guard value.isFinite else { return }
                    Task { @MainActor in
                        if !state.isFinished { progress(min(1, max(0, value))) }
                    }
                }
                let id = start(options) { image, info in
                    if info?[PHImageCancelledKey] as? Bool == true {
                        state.finish(.failure(CancellationError())); return
                    }
                    if let error = info?[PHImageErrorKey] as? Error {
                        state.finish(.failure(error)); return
                    }
                    if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
                    if let image { state.finish(.success(image)) }
                    else {
                        let message = info?[PHImageResultIsInCloudKey] as? Bool == true
                            ? "iCloud 照片暂未能下载，请检查网络或 iCloud 登录状态后重试。"
                            : "照片预览暂不可用，请重试。"
                        state.finish(.failure(ReviewError.message(message)))
                    }
                }
                state.setRequestID(id)
            }
        } onCancel: { state.finish(.failure(CancellationError())) }
    }

    @MainActor static func jpeg(_ image: NSImage) throws -> Data {
        let scale = min(1, 768 / max(image.size.width, image.size.height))
        let size = NSSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        // Redraw pixels so GPS/EXIF metadata and the original file never enter the request.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ReviewError.message("照片预览转换失败，请重新选择照片。")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.67]) else {
            throw ReviewError.message("照片预览转换失败，请重新选择照片。")
        }
        return data
    }
}

struct ModelSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
    @State private var model = "qwen3-vl-flash"
    @State private var apiKey = ""
    @State private var revealKey = false
    @State private var message = ""
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("连接视觉模型").font(.title2.bold())
            Text("使用供应商提供的 OpenAI 兼容地址及支持图片的模型。API Key 只保存在本机钥匙串。")
                .foregroundStyle(.secondary)
            Form {
                TextField("服务地址", text: $baseURL)
                TextField("视觉模型", text: $model)
                HStack {
                    if revealKey { TextField("API Key", text: $apiKey) }
                    else { SecureField("API Key", text: $apiKey) }
                    Button(revealKey ? "隐藏" : "显示") { revealKey.toggle() }
                        .accessibilityLabel(revealKey ? "隐藏 API Key" : "显示 API Key")
                }
            }.disabled(testing)
            Text("测试连接只发送文字。分析照片前会另行显示发送范围；请求可能产生供应商费用。")
                .font(.callout).foregroundStyle(.secondary)
            Text(message).font(.callout).textSelection(.enabled).frame(minHeight: 40, alignment: .topLeading)
                .accessibilityLabel("连接状态：\(message)")
            HStack {
                Button("取消") { testTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("导入 .env") { importEnvironment() }.disabled(testing)
                Button("测试连接") { testConnection() }.disabled(testing)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("保存设置") { save() }.buttonStyle(.borderedProminent).disabled(testing)
            }
        }
        .padding(28).frame(width: 560)
        .onAppear {
            do {
                let settings = try ModelConfiguration.load()
                baseURL = settings.baseURL; model = settings.model; apiKey = settings.apiKey
            } catch { message = error.localizedDescription }
        }
        .onDisappear { testTask?.cancel() }
        .interactiveDismissDisabled()
    }

    private var configuration: ModelConfiguration {
        ModelConfiguration(baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                           model: model.trimmingCharacters(in: .whitespacesAndNewlines),
                           apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func save() {
        do {
            try configuration.validate()
            try ModelKeychain.save(configuration.apiKey)
            UserDefaults.standard.set(configuration.baseURL, forKey: "modelBaseURL")
            UserDefaults.standard.set(configuration.model, forKey: "visionModel")
            dismiss()
        } catch { message = error.localizedDescription }
    }

    private func importEnvironment() {
        let panel = NSOpenPanel()
        panel.title = "选择现有模型 .env 配置"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try ModelConfiguration.importing(url, fallback: configuration)
            baseURL = imported.baseURL; model = imported.model; apiKey = imported.apiKey
            message = "已导入，请核对服务地址和模型，再测试或保存。"
        } catch { message = error.localizedDescription }
    }

    private func testConnection() {
        do { try configuration.validate() } catch { message = error.localizedDescription; return }
        testing = true
        message = "正在发送文字测试…"
        let settings = configuration
        testTask = Task { @MainActor in
            defer { testing = false }
            do {
                let response = try await VisionModel.request(configuration: settings,
                    content: [["type": "text", "text": "Return {\"ok\":true}"]], instruction: "Return JSON only.")
                struct Probe: Decodable { let ok: Bool }
                guard let probe = try? JSONDecoder().decode(Probe.self, from: Data(response.utf8)), probe.ok else {
                    throw ReviewError.message("连接成功，但模型没有返回预期 JSON。请检查兼容性。")
                }
                try Task.checkCancellation()
                message = "连接成功。图片理解能力将在选片分析时验证。"
            } catch { message = Task.isCancelled ? "已取消测试。" : "测试失败：\(error.localizedDescription)" }
        }
    }
}

struct PhotoReviewSheet: View {
    let assets: [PHAsset]
    @Bindable var library: PhotoLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var reason = ""
    @State private var image: NSImage?
    @State private var keeperImage: NSImage?
    @State private var loading = true
    @State private var keeperLoading = false
    @State private var downloadProgress: Double?
    @State private var keeperProgress: Double?
    @State private var previewError: String?
    @State private var keeperError: String?
    @State private var previewAttempt = 0
    private var asset: PHAsset { assets[index] }
    private var review: PhotoReview? { library.reviews[asset.localIdentifier] }
    private var protected: Bool { library.memory.protectedIDs.contains(asset.localIdentifier) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("快速审核").font(.title2.bold())
                Spacer()
                Text("\(index + 1) / \(assets.count)").monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                preview(image, title: "当前照片", loading: loading, progress: downloadProgress, error: previewError)
                if review?.keeperAssetID != nil { preview(keeperImage, title: "对比保留项", loading: keeperLoading, progress: keeperProgress, error: keeperError) }
            }.frame(height: 290)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let review {
                        Text(review.advice.decision.label).font(.headline)
                        Text(review.advice.reason).textSelection(.enabled)
                        if protected { Text("这是同组的对比保留项，请至少留下一张。").font(.caption).foregroundStyle(.secondary) }
                    } else { Text("尚未分析，可先关闭并点击“分析全部”。") }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 100)
            TextField("为什么删 / 留？（选填，自动记入偏好）", text: $reason, axis: .vertical)
                .lineLimit(2...3).textFieldStyle(.roundedBorder)
            HStack(spacing: 16) {
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("稍后再看") { next() }
                Spacer()
                Button { choose(.cleanup) } label: {
                    Label("删", systemImage: "trash.fill").font(.title3.bold()).frame(minWidth: 110, minHeight: 32)
                }.buttonStyle(.borderedProminent).tint(DesignTokens.delete).controlSize(.large)
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(review == nil || protected || loading || image == nil || library.isBusy)
                    .help("加入待删除图库，尚未从系统图库删除。⌘D")
                Button { choose(.keep) } label: {
                    Label(library.pendingDeletion.contains(asset.localIdentifier) ? "复活 / 留" : "留", systemImage: "heart.fill")
                        .font(.title3.bold()).frame(minWidth: 110, minHeight: 32)
                }.buttonStyle(.borderedProminent).tint(DesignTokens.keep).controlSize(.large)
                    .keyboardShortcut("k", modifiers: .command).disabled(review == nil || library.isBusy)
                    .help("保留并记住反馈。⌘K")
            }
            Text(library.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.padding(28).frame(width: 700)
        .interactiveDismissDisabled()
        .onChange(of: asset.localIdentifier) { _, _ in reason = "" }
        .task(id: "\(asset.localIdentifier)-\(previewAttempt)") {
            image = nil; keeperImage = nil; loading = true
            keeperLoading = review?.keeperAssetID != nil
            downloadProgress = nil; keeperProgress = nil; previewError = nil; keeperError = nil
            let attempt = previewAttempt
            do {
                let result = try await PhotoImages.preview(asset, size: 1600) { value in
                    if loading && previewAttempt == attempt { downloadProgress = value }
                }
                guard !Task.isCancelled else { return }
                image = result
            } catch {
                guard !Task.isCancelled else { return }
                previewError = error.localizedDescription
            }
            loading = false
            if let keeper = review?.keeperAssetID,
               let other = PHAsset.fetchAssets(withLocalIdentifiers: [keeper], options: nil).firstObject {
                do {
                    let result = try await PhotoImages.preview(other, size: 1600) { value in
                        if keeperLoading && previewAttempt == attempt { keeperProgress = value }
                    }
                    guard !Task.isCancelled else { return }
                    keeperImage = result
                } catch {
                    guard !Task.isCancelled else { return }
                    keeperError = error.localizedDescription
                }
            }
            keeperLoading = false
        }
    }

    private func choose(_ decision: PhotoDecision) {
        if library.decide([asset.localIdentifier], decision: decision, reason: reason) { next() }
    }
    private func next() {
        if index + 1 < assets.count { index += 1 } else { dismiss() }
    }
    private func preview(_ value: NSImage?, title: String, loading: Bool, progress: Double?, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ZStack {
                DesignTokens.thumbnailBackground
                if let value { Image(nsImage: value).resizable().scaledToFit() }
                else if loading {
                    if let progress { ProgressView("iCloud 下载 \(Int(progress * 100))%", value: progress).padding(24) }
                    else { ProgressView("正在读取预览…") }
                } else {
                    VStack(spacing: 12) {
                        Text(error ?? "照片预览暂不可用。").font(.callout).multilineTextAlignment(.center)
                        Button("重试读取预览") { previewAttempt += 1 }
                    }.padding()
                }
            }.clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
        }.frame(maxWidth: .infinity)
    }
}

struct PreferenceHistorySheet: View {
    @Bindable var library: PhotoLibraryModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("偏好记录 · v\(library.memory.preferenceVersion)").font(.title2.bold())
            Text("完整记录保存在本机，压缩为有条件、有例外、可追溯的长期偏好。新纠正优先，无理由选择仅作个例线索。点“更新记忆与自进化”归纳新反馈；分析照片不会等待归纳。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("更新记忆与自进化") { library.refreshLearning() }
                    .disabled(library.isBusy || library.feedbackCount == 0)
                Button("回滚策略") { library.rollbackLearning() }
                    .disabled(library.isBusy || library.memory.learning?.active == nil)
                if library.isLearning { Button("取消") { library.cancelAnalysis() } }
            }
            Group {
                if library.isLearning, let started = library.learningRequestStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("等待模型响应 · \(Int(max(0, context.date.timeIntervalSince(started)))) 秒 · 可随时取消")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                } else { Text(" ").font(.caption).hidden() }
            }.frame(height: 18, alignment: .leading)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(library.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("压缩后的长期偏好").font(.headline)
                    let rules = library.memory.learning?.digest.validRules(for: library.memory.latestFeedback) ?? []
                    if rules.isEmpty { Text("还没有已归纳的有理由偏好。").foregroundStyle(.secondary) }
                    let examples = library.memory.learning?.digest.exampleIDs?.count ?? 0
                    if examples > 0 {
                        Text("另有 \(examples) 条无理由个例已保存在本机，作为相似线索使用，无需等待模型改写。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(rule.action == .keep ? "倾向保留" : "倾向清理").font(.headline)
                            Text(rule.condition).fixedSize(horizontal: false, vertical: true)
                            Text("例外：" + rule.exceptions).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text("来自 \(rule.evidence.count) 条有效反馈").font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                    Text("自进化").font(.headline)
                    Text("有反馈就学习，另留部分照片验证，同组对比照片放在一起。新策略只有减少人工改动且不增加误清理、不降低清理召回才启用。验证会向已配置的模型发送本地缩略图，不执行系统删除。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(library.memory.learning?.status ?? PreferenceLearning().status).fixedSize(horizontal: false, vertical: true)
                    ForEach((library.memory.learning?.versions ?? []).reversed()) { version in
                        Text("h\(version.id) · \(version.accepted ? "验证通过" : "未通过") · 需改动 \(version.baseline.edits)→\(version.candidate.edits)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("原始反馈依据（全部 \(library.feedbackCount) 条）") {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if library.memory.feedback.isEmpty { Text("还没有用户反馈，模型自己的决定不会写成你的偏好。").foregroundStyle(.secondary) }
                            ForEach(Array(library.memory.feedback.reversed())) { item in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("\(item.action == .keep ? "用户保留 / 复活" : "用户选择删除") · \(item.date.formatted(date: .abbreviated, time: .shortened))").font(.headline)
                                    Text(item.reason.isEmpty ? "未填写理由" : "你的理由：\(item.reason)")
                                    Text("模型当时的描述：\(item.modelObservation)").font(.caption).foregroundStyle(.secondary)
                                }
                                Divider()
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 400)
            HStack {
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("清空反馈记忆", role: .destructive) { library.clearFeedback() }
                    .disabled(library.feedbackCount == 0 || library.isBusy)
            }
        }.padding(28).frame(width: 620)
    }
}
