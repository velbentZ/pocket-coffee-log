import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public struct OnDeviceAICapabilities: Equatable, Sendable {
    public var onDeviceSpeechAvailable: Bool
    public var visionOCRAvailable: Bool
    public var appleFoundationModelsAvailable: Bool
    public var activeAdvisorName: String
    public var summaryText: String

    public init(
        onDeviceSpeechAvailable: Bool,
        visionOCRAvailable: Bool,
        appleFoundationModelsAvailable: Bool,
        activeAdvisorName: String,
        summaryText: String
    ) {
        self.onDeviceSpeechAvailable = onDeviceSpeechAvailable
        self.visionOCRAvailable = visionOCRAvailable
        self.appleFoundationModelsAvailable = appleFoundationModelsAvailable
        self.activeAdvisorName = activeAdvisorName
        self.summaryText = summaryText
    }

    public static func currentCapabilities() -> OnDeviceAICapabilities {
        let speechAvailable = AppleOnDeviceMediaRecognizer.onDeviceSpeechAvailable()
        let visionAvailable = true
        let fmAvailable = AppleFoundationModelAdvisor.isFoundationModelAvailable
        let activeAdvisor = fmAvailable
            ? "Apple Foundation Models (端侧大模型)"
            : "本地咖啡师规则引擎 (100% 离线)"

        let speechLabel = speechAvailable ? "离线语音识别已就绪" : "语音识别需授权或下载离线包"
        let fmLabel = fmAvailable ? "端侧 Apple Intelligence 已启用" : "端侧大模型未启用，自动使用离线咖啡师规则引擎"
        let summary = "\(speechLabel) · Vision OCR 已就绪 · \(fmLabel)"

        return OnDeviceAICapabilities(
            onDeviceSpeechAvailable: speechAvailable,
            visionOCRAvailable: visionAvailable,
            appleFoundationModelsAvailable: fmAvailable,
            activeAdvisorName: activeAdvisor,
            summaryText: summary
        )
    }
}

public protocol OnDeviceBaristaAdvising: Sendable {
    var backendName: String { get }
    var isAvailable: Bool { get }
    func enhance(record: inout CoffeeRecord, recognition: RecognitionOutput) async
}

public struct RuleBasedOfflineAdvisor: OnDeviceBaristaAdvising {
    public init() {}

    public var backendName: String { "rule_based_offline" }
    public var isAvailable: Bool { true }

    public func enhance(record: inout CoffeeRecord, recognition: RecognitionOutput) async {
        ChineseCoffeeAnalyzer.enrichBaristaAnalysis(&record)
    }
}

public struct AppleFoundationModelAdvisor: OnDeviceBaristaAdvising {
    private let fallback: RuleBasedOfflineAdvisor

    public init(fallback: RuleBasedOfflineAdvisor = RuleBasedOfflineAdvisor()) {
        self.fallback = fallback
    }

    public static var isFoundationModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }

    public var isAvailable: Bool {
        Self.isFoundationModelAvailable
    }

    public var backendName: String {
        isAvailable ? "apple_foundation_models" : fallback.backendName
    }

    public func enhance(record: inout CoffeeRecord, recognition: RecognitionOutput) async {
        // Always run deterministic offline enrichment first so every field has a reliable baseline.
        await fallback.enhance(record: &record, recognition: recognition)

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *),
           case .available = SystemLanguageModel.default.availability {
            await refineWithFoundationModels(record: &record, recognition: recognition)
        }
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private func refineWithFoundationModels(
        record: inout CoffeeRecord,
        recognition: RecognitionOutput
    ) async {
        let instructions = """
        你是一位资深精品咖啡师与萃取诊断顾问。请完全基于用户提供的冲煮参数或器具记录，用简洁专业的中文返回严格 JSON 对象，不要输出任何 Markdown 代码块或多余解释。
        JSON 字段：
        {
          "extraction_diagnosis": "1-2句专业萃取诊断或器具建档总结",
          "suggestions": ["具体可执行的微调建议1", "具体可执行的微调建议2"],
          "xiaohongshu_copy": "适合小红书发布的真实感咖啡日记文案（含参数与标签）",
          "wechat_copy": "适合朋友圈发布的简短精致文案"
        }
        """

        let prompt = buildPrompt(for: record, recognition: recognition)
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            applyJSONRefinement(response.content, to: &record)
        } catch {
            // Gracefully retain deterministic offline analysis on any on-device model error.
        }
    }
    #endif

    private func buildPrompt(for record: CoffeeRecord, recognition: RecognitionOutput) -> String {
        let safeDevice = AppleOnDeviceMediaRecognizer.sanitizeCaptureDeviceName(record.cameraDevice)
            ?? record.sourceType.displayName
        let safeTranscript = String(recognition.transcript.prefix(4_000))
        if record.recordType == .equipmentProfile {
            let itemsDesc = record.equipmentItems.prefix(20).map { "\($0.name)(\($0.category))" }.joined(separator: "、")
            return """
            记录类型：常驻器具档案
            设备来源：\(safeDevice)
            识别器具：\(itemsDesc.isEmpty ? "居家意式器具" : itemsDesc)
            口播原文：\(safeTranscript)
            """
        }

        return """
        记录类型：冲煮报告
        豆子：\(record.beanName ?? "未知")（\(record.beanRoast ?? "未注明烘焙度")）
        粉量：\(record.beanWeightG.map { String(format: "%.1fg", $0) } ?? "未记录")
        研磨度：\(record.grindSetting ?? "未记录") / 磨豆机：\(record.grinderModel ?? "未记录")
        方式：\(record.brewMethod ?? "意式浓缩")
        液重：\(record.yieldG.map { String(format: "%.1fg", $0) } ?? "未记录")，粉液比：\(record.brewRatio ?? "未计算")
        时间：\(record.extractionTimeS.map { String(format: "%.1fs", $0) } ?? "未记录")，压力：\(record.pressureBar.map { String(format: "%.1f bar", $0) } ?? "未记录")，水温：\(record.waterTempC.map { String(format: "%.1f°C", $0) } ?? "未记录")
        口播原文：\(safeTranscript)
        """
    }

    private func applyJSONRefinement(_ rawText: String, to record: inout CoffeeRecord) {
        var cleaned = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        guard let startIdx = cleaned.firstIndex(of: "{"),
              let endIdx = cleaned.lastIndex(of: "}")
        else {
            return
        }
        let jsonSlice = String(cleaned[startIdx...endIdx])
        guard let data = jsonSlice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }

        if let diagnosis = (obj["extraction_diagnosis"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !diagnosis.isEmpty {
            record.extractionDiagnosis = diagnosis
        }
        if let suggestions = obj["suggestions"] as? [String] {
            let cleanedSuggestions = suggestions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !cleanedSuggestions.isEmpty {
                record.suggestions = cleanedSuggestions
            }
        }
        if let xhs = (obj["xiaohongshu_copy"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !xhs.isEmpty {
            record.xiaohongshuCopy = xhs
        }
        if let wechat = (obj["wechat_copy"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !wechat.isEmpty {
            record.wechatCopy = wechat
        }
    }
}
