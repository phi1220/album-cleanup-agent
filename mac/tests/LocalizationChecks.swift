import Foundation

func checkLocalization() throws -> Int {
    var checks = 0
    let han = try NSRegularExpression(pattern: #"\p{sc=Han}"#)
    func containsHan(_ text: String) -> Bool {
        han.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) > 0
    }
    var catalogs: [String: [String: String]] = [:]
    for language in L10n.supportedLanguages {
        let bundle = L10n.bundle(for: language)
        precondition(bundle.bundleURL.pathExtension == "lproj", "Missing bundled language: \(language)")
        let url = bundle.url(forResource: "Localizable", withExtension: "strings")!
        let catalog = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: String]
        precondition(catalog.count >= 200)
        catalogs[language] = catalog
        let info = bundle.url(forResource: "InfoPlist", withExtension: "strings")!
        let labels = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as! [String: String]
        precondition(labels["NSPhotoLibraryUsageDescription"]?.isEmpty == false)
        precondition(labels["CFBundleDisplayName"] == "ByePhoto" && labels["CFBundleName"] == "ByePhoto")
        checks += 3
    }
    let english = catalogs["en"]!, chinese = catalogs["zh-Hans"]!
    precondition(Set(english.keys) == Set(chinese.keys)); checks += 1
    let placeholders = try NSRegularExpression(pattern: #"%(?:\d+\$)?@"#)
    for key in chinese.keys {
        let translated = english[key]!
        func count(_ text: String) -> Int {
            placeholders.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        precondition(count(key) == count(translated), "Format arguments differ: \(key)")
        precondition(!containsHan(translated), "Untranslated English copy: \(key)")
        checks += 1
    }
    // Check the shipped catalogs against every actual call site, including escaped newlines.
    let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let calls = try NSRegularExpression(pattern: #"\btr\("((?:[^"\\]|\\.)*)""#)
    var used: Set<String> = []
    for path in try FileManager.default.contentsOfDirectory(at: sourceRoot, includingPropertiesForKeys: nil)
        where path.pathExtension == "swift" {
        let source = try String(contentsOf: path, encoding: .utf8)
        for match in calls.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let raw = String(source[Range(match.range(at: 1), in: source)!])
            let key = try JSONDecoder().decode(String.self, from: Data(("\"" + raw + "\"").utf8))
            precondition(english[key] != nil && chinese[key] != nil, "Missing translation: \(key)")
            used.insert(key)
        }
    }
    precondition(used == Set(english.keys), "Unused or missing localization keys"); checks += 1
    let readme = try String(contentsOf: sourceRoot.deletingLastPathComponent().appendingPathComponent("README.md"), encoding: .utf8)
    precondition(readme.hasPrefix("# ByePhoto\n") && !containsHan(readme),
        "Chinese text leaked into the English README")
    precondition(readme.contains(#"open ".build/ByePhoto.app""#)
        && readme.contains("[Simplified Chinese](README.zh-CN.md)")
        && FileManager.default.fileExists(atPath: sourceRoot.deletingLastPathComponent().appendingPathComponent("README.zh-CN.md").path))
    checks += 2
    precondition(L10n.language(for: "system", preferred: ["en-US"]) == "en")
    precondition(L10n.language(for: "system", preferred: ["zh-Hans-CN"]) == "zh-Hans")
    precondition(L10n.language(for: "en", preferred: ["zh-Hans"]) == "en")
    precondition(L10n.language(for: "zh-Hans", preferred: ["en"]) == "zh-Hans")
    checks += 4
    UserDefaults.standard.set("en", forKey: L10n.languageKey)
    precondition(tr("本次已完成 %@/%@ 张", "7", "100") == "Photos analyzed: 7/100")
    precondition(tr("简体中文") == "Simplified Chinese" && tr("ByePhoto") == "ByePhoto")
    precondition(tr("iCloud 下载 %@%%", "50") == "iCloud download 50%")
    precondition(tr("%@；第 %@/%@ 批 %@ 张正在上传和分析…", "Progress", "2", "10", "8")
        == "Progress; uploading and analyzing 8 photos in batch 2/10…")
    precondition(tr("第 %@ 批第 %@ 张未能读取：%@；保留待重试。", "2", "8", "offline")
        == "Could not load photo 8 in batch 2: offline; kept for retry.")
    precondition(L10n.modelInstruction.contains("in English"))
    let request = try VisionModel.makeRequest(configuration: ModelConfiguration(baseURL: "https://example.com/v1", model: "synthetic", apiKey: "synthetic"),
        content: [["type": "text", "text": "synthetic input"]], instruction: ReviewProtocol.instruction)
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    let system = (body["messages"] as! [[String: Any]])[0]["content"] as! String
    precondition(system.hasPrefix(ReviewProtocol.instruction) && system.hasSuffix(L10n.modelInstruction))
    precondition(ReviewError.serviceStatus(429).errorDescription!.contains("HTTP 429"))
    precondition(L10n.storedStatus("已回滚至 基础策略；长期偏好仍保留。") == "Rolled back to base policy. Long-term preferences are preserved.")
    precondition(L10n.storedStatus("自定义历史内容保持原文") == "自定义历史内容保持原文")
    let stored = L10n.storedStatus("偏好已归纳；可回放验证照片 13 张，暂缺保留或清理证据，沿用当前策略。已删除、改变或无本地预览的照片跳过验证。")
    precondition(stored.hasPrefix("Preferences summarized. 13 photos"))
    UserDefaults.standard.set("zh-Hans", forKey: L10n.languageKey)
    precondition(tr("本次已完成 %@/%@ 张", "7", "100") == "本次已完成 7/100 张")
    precondition(L10n.modelInstruction.contains("简体中文"))
    precondition(L10n.storedStatus(stored).hasPrefix("偏好已归纳；可回放验证照片 13 张"))
    checks += 14
    return checks
}
