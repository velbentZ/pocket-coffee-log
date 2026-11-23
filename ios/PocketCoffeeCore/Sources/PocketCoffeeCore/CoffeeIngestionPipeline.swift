import Foundation

public final class CoffeeIngestionPipeline: @unchecked Sendable {
    public static let maxTranscriptChars = 20_000
    public static let maxOCRLines = 160
    public static let maxOCRLineChars = 400
    public static let maxOCRCorpusChars = 8_000

    public let recordStore: RecordStore
    public let beanStore: BeanEquipmentStore
    public let recognizer: MediaRecognizing
    public let advisor: OnDeviceBaristaAdvising

    public init(
        recordStore: RecordStore,
        beanStore: BeanEquipmentStore,
        recognizer: MediaRecognizing? = nil,
        advisor: OnDeviceBaristaAdvising = AppleFoundationModelAdvisor()
    ) {
        self.recordStore = recordStore
        self.beanStore = beanStore
        self.recognizer = recognizer ?? AppleOnDeviceMediaRecognizer(knownBeans: beanStore.loadLibrary().beans)
        self.advisor = advisor
    }

    /// Module 1: Standalone media recognition (audio ASR + video keyframe OCR).
    /// Does not generate a report or mutate `recordStore` / `beanStore`.
    public func recognizeMedia(
        mediaURL: URL?,
        spokenTranscript: String = "",
        sourceDevice: String = "iPhone 手机录制",
        hintOverrides: VisualFieldReadings? = nil,
        extractFrames: Bool = true
    ) async -> RecognitionOutput {
        await recognizer.recognizeMedia(
            mediaURL: mediaURL,
            spokenTranscript: spokenTranscript,
            sourceDevice: sourceDevice,
            hintOverrides: hintOverrides,
            extractFrames: extractFrames
        )
    }

    /// Module 2: Standalone report or equipment-profile generation from a `RecognitionOutput`.
    public func generateReport(
        from recognition: RecognitionOutput,
        sourceType: SourceType = .iphone,
        recordIntent: RecordIntent = .auto,
        save: Bool = true
    ) async -> PipelineResult {
        let fullTranscript = String(recognition.transcript.prefix(Self.maxTranscriptChars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDevice = AppleOnDeviceMediaRecognizer.sanitizeCaptureDeviceName(recognition.sourceDevice)
            ?? sourceType.displayName

        // Collect deduplicated on-screen subtitle / OCR text across extracted keyframes under strict size caps
        var seenOCR = Set<String>()
        var ocrLines: [String] = []
        var totalOCRChars = 0
        outerOCR: for kf in recognition.keyframes.prefix(16) {
            for rawLine in kf.ocrTexts.prefix(120) {
                let cleaned = String(rawLine.prefix(Self.maxOCRLineChars))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard cleaned.count >= 2 else { continue }
                if seenOCR.insert(cleaned.lowercased()).inserted {
                    if ocrLines.count >= Self.maxOCRLines || totalOCRChars + cleaned.count > Self.maxOCRCorpusChars {
                        break outerOCR
                    }
                    ocrLines.append(cleaned)
                    totalOCRChars += cleaned.count + 1
                }
            }
        }
        let ocrCorpus = String(ocrLines.joined(separator: "\n").prefix(Self.maxOCRCorpusChars))
        let rawAnalysisText: String
        if fullTranscript.isEmpty {
            rawAnalysisText = ocrCorpus
        } else if ocrCorpus.isEmpty {
            rawAnalysisText = fullTranscript
        } else {
            rawAnalysisText = "\(fullTranscript)\n\(ocrCorpus)"
        }
        let analysisText = String(rawAnalysisText.prefix(Self.maxTranscriptChars + Self.maxOCRCorpusChars))

        let library = beanStore.loadLibrary()
        let matchedBean = beanStore.matchBean(in: analysisText)
            ?? recognition.visualFields.beanName.flatMap { beanStore.matchBean(in: $0) }

        // Gatekeeper: reject clearly non-coffee content so unrelated audio/video/text never pollutes records or equipment
        if !ChineseCoffeeAnalyzer.isCoffeeRelated(
            transcript: fullTranscript,
            visualFields: recognition.visualFields,
            matchedBean: matchedBean,
            ocrTexts: ocrLines,
            visualSceneTags: recognition.visualSceneTags
        ) {
            let reason = "未检测到咖啡制作或器具相关内容，已自动拦截，未写入档案库。"
            var rejected = CoffeeRecord(
                cameraDevice: resolvedDevice,
                sourceType: sourceType,
                mediaKind: recognition.mediaKind,
                videoPath: recognition.mediaPath,
                mediaURL: recognition.mediaPath,
                transcript: fullTranscript,
                extractionDiagnosis: reason,
                recordType: .brewReport,
                status: "rejected"
            )
            rejected.keyframes = recognition.keyframes
            return PipelineResult(
                record: rejected,
                recognition: recognition,
                saved: false,
                updatedEquipment: nil,
                deductedBean: nil,
                advisorBackend: advisor.backendName,
                rejectedAsNonCoffee: true,
                rejectionReason: reason
            )
        }

        var record = ChineseCoffeeAnalyzer.extractParameters(
            transcript: analysisText,
            cameraDevice: resolvedDevice,
            sourceType: sourceType,
            mediaKind: recognition.mediaKind,
            videoPath: recognition.mediaPath,
            visualOverrides: recognition.visualFields,
            matchedBean: matchedBean,
            equipmentDefaults: library.equipment
        )
        // Keep stored transcript readable: prefer spoken transcript, or fall back to compact OCR caption summary
        if !fullTranscript.isEmpty {
            record.transcript = fullTranscript
        } else if !ocrCorpus.isEmpty {
            record.transcript = "[画面字幕/OCR] \(String(ocrLines.prefix(12).joined(separator: " | ").prefix(600)))"
        }

        record.sourceType = sourceType
        record.mediaKind = recognition.mediaKind
        record.mediaURL = recognition.mediaPath

        // Fill any fields still missing from visual OCR readings
        applyVisualFallbacks(recognition.visualFields, to: &record)
        if let matchedBean, !matchedBean.fullName.isEmpty {
            record.beanName = matchedBean.fullName
        }

        // Resolve record intent ("auto" | "brew_report" | "equipment_profile")
        switch recordIntent {
        case .equipmentProfile:
            record.recordType = .equipmentProfile
            if record.equipmentItems.isEmpty {
                record.equipmentItems = ChineseCoffeeAnalyzer.extractEquipmentItems(from: analysisText)
            }
            if record.brewMethod == nil || record.brewMethod?.isEmpty == true {
                record.brewMethod = "常驻设备与器具档案补充"
            }
            if record.beanName == nil || record.beanName?.isEmpty == true {
                record.beanName = "\(record.grinderModel ?? "居家咖啡机") · 全套器具建档"
            }
        case .brewReport:
            record.recordType = .brewReport
        case .auto:
            if record.recordType != .equipmentProfile,
               ChineseCoffeeAnalyzer.isEquipmentIntroduction(transcript: analysisText, record: record) {
                record.recordType = .equipmentProfile
                record.equipmentItems = ChineseCoffeeAnalyzer.extractEquipmentItems(from: analysisText)
                if record.brewMethod == nil || record.brewMethod?.isEmpty == true {
                    record.brewMethod = "常驻设备与器具档案补充"
                }
                if record.beanName == nil || record.beanName?.isEmpty == true {
                    record.beanName = "\(record.grinderModel ?? "居家咖啡机") · 全套器具建档"
                }
            }
        }

        // For silent/ASMR coffee videos verified via visual scene evidence with no explicit method text
        if record.recordType == .brewReport,
           (record.brewMethod ?? "").isEmpty,
           !recognition.visualSceneTags.isEmpty {
            let tags = Set(recognition.visualSceneTags.map { $0.lowercased() })
            if !tags.isDisjoint(with: ["machine", "appliance", "coffee_maker", "espresso_maker", "espresso"]) {
                record.brewMethod = "意式浓缩/奶咖 (纯视觉识别)"
            } else {
                record.brewMethod = "日常咖啡冲煮 (纯视觉/ASMR)"
            }
        }

        // Populate structured equipmentItems (including detected espresso machine brand/model) on brew reports too
        if record.recordType == .brewReport {
            let mentionedItems = ChineseCoffeeAnalyzer.extractMentionedEquipmentItems(from: analysisText)
            if !mentionedItems.isEmpty {
                var existingIDs = Set(record.equipmentItems.map(\.id))
                for item in mentionedItems where existingIDs.insert(item.id).inserted {
                    record.equipmentItems.append(item)
                }
            }
        }

        var keyframes = recognition.keyframes
        if record.recordType == .equipmentProfile && !keyframes.isEmpty {
            keyframes = ChineseCoffeeAnalyzer.relabelKeyframesForEquipmentProfile(
                keyframes,
                items: record.equipmentItems
            )
        }
        record.keyframes = keyframes

        record.computeDerivedMetrics()
        await advisor.enhance(record: &record, recognition: recognition)

        var updatedEquipment: EquipmentProfile?
        if save && record.recordType == .equipmentProfile {
            let inferredMachine = inferEspressoMachine(from: record)
            updatedEquipment = beanStore.updateEquipmentFromIntro(
                equipmentItems: record.equipmentItems,
                grinderType: record.grinderType,
                grinderModel: record.grinderModel,
                espressoMachine: inferredMachine
            )
        } else if save && record.recordType == .brewReport {
            // Also auto-import any explicitly mentioned coffee accessories from brew reports
            let mentionedAccessories = ChineseCoffeeAnalyzer.extractMentionedEquipmentItems(from: analysisText)
            if !mentionedAccessories.isEmpty {
                updatedEquipment = beanStore.updateEquipmentFromIntro(
                    equipmentItems: mentionedAccessories,
                    grinderType: nil,
                    grinderModel: nil,
                    espressoMachine: nil
                )
            }
        }

        let hasAnyCapturedInfo =
            record.recordType == .equipmentProfile
            || !(record.beanName ?? "").isEmpty
            || !(record.brewMethod ?? "").isEmpty
            || !(record.grinderModel ?? "").isEmpty
            || record.beanWeightG != nil
            || record.yieldG != nil
            || record.extractionTimeS != nil
            || record.pressureBar != nil
            || record.waterTempC != nil
            || !(record.grindSetting ?? "").isEmpty
            || !fullTranscript.isEmpty
            || !ocrCorpus.isEmpty
            || !recognition.visualFields.asDisplayDictionary.isEmpty
            || !recognition.visualSceneTags.isEmpty

        let didSave = save && hasAnyCapturedInfo
        if didSave {
            recordStore.saveRecord(record)
        }

        var deductedBean: BeanEntry?
        if save,
           record.recordType != .equipmentProfile,
           let beanName = record.beanName,
           !beanName.isEmpty {
            deductedBean = beanStore.upsertBeanFromBrewRecord(record)
        }

        return PipelineResult(
            record: record,
            recognition: recognition,
            saved: didSave,
            updatedEquipment: updatedEquipment,
            deductedBean: deductedBean,
            advisorBackend: advisor.backendName
        )
    }

    /// Module 3: End-to-end device-agnostic media ingestion (recognize -> generate -> persist).
    public func ingestMedia(
        mediaURL: URL?,
        spokenTranscript: String = "",
        sourceDevice: String = "",
        sourceType: SourceType = .iphone,
        recordIntent: RecordIntent = .auto,
        hintOverrides: VisualFieldReadings? = nil,
        extractFrames: Bool = true,
        save: Bool = true
    ) async -> PipelineResult {
        let resolvedDevice = AppleOnDeviceMediaRecognizer.sanitizeCaptureDeviceName(sourceDevice)
            ?? sourceType.displayName

        let recognition = await recognizeMedia(
            mediaURL: mediaURL,
            spokenTranscript: spokenTranscript,
            sourceDevice: resolvedDevice,
            hintOverrides: hintOverrides,
            extractFrames: extractFrames
        )

        return await generateReport(
            from: recognition,
            sourceType: sourceType,
            recordIntent: recordIntent,
            save: save
        )
    }

    /// Supplement an existing record with additional text notes and/or string-keyed field updates.
    @discardableResult
    public func supplementRecord(
        id: String,
        supplementText: String = "",
        updates: [String: String]
    ) -> CoffeeRecord? {
        guard var existing = recordStore.getRecord(id: id) else {
            return nil
        }

        let trimmedSupplement = String(supplementText.prefix(4_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSupplement.isEmpty {
            applySupplementText(trimmedSupplement, to: &existing)
        }

        for (key, rawValue) in updates {
            let trimmed = String(rawValue.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            switch key {
            case "bean_name": existing.beanName = trimmed
            case "bean_roast": existing.beanRoast = trimmed
            case "bean_weight_g": if let v = Double(trimmed), v.isFinite, v > 0, v <= 100_000 { existing.beanWeightG = v }
            case "grind_setting": existing.grindSetting = trimmed
            case "grinder_type": existing.grinderType = trimmed
            case "grinder_model": existing.grinderModel = trimmed
            case "brew_method": existing.brewMethod = trimmed
            case "yield_g": if let v = Double(trimmed), v.isFinite, v > 0, v <= 100_000 { existing.yieldG = v }
            case "extraction_time_s": if let v = Double(trimmed), v.isFinite, v > 0, v <= 100_000 { existing.extractionTimeS = v }
            case "pressure_bar": if let v = Double(trimmed), v.isFinite, v > 0, v <= 100_000 { existing.pressureBar = v }
            case "water_temp_c": if let v = Double(trimmed), v.isFinite, v > 0, v <= 110 { existing.waterTempC = v }
            default: break
            }
        }

        existing.computeDerivedMetrics()
        ChineseCoffeeAnalyzer.enrichBaristaAnalysis(&existing)
        recordStore.saveRecord(existing)
        return existing
    }

    /// Supplement an existing record with additional text notes and/or structured parameter updates.
    @discardableResult
    public func supplementRecord(
        id: String,
        supplementText: String = "",
        updates: VisualFieldReadings? = nil
    ) -> CoffeeRecord? {
        guard var existing = recordStore.getRecord(id: id) else {
            return nil
        }

        let trimmedSupplement = String(supplementText.prefix(4_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSupplement.isEmpty {
            applySupplementText(trimmedSupplement, to: &existing)
        }

        if let updates {
            if let v = updates.beanName?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                existing.beanName = String(v.prefix(200))
            }
            if let v = updates.beanWeightG, v.isFinite, v > 0, v <= 100_000 { existing.beanWeightG = v }
            if let v = updates.grindSetting?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                existing.grindSetting = String(v.prefix(200))
            }
            if let v = updates.grinderModel?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                existing.grinderModel = String(v.prefix(200))
            }
            if let v = updates.pressureBar, v.isFinite, v > 0, v <= 100_000 { existing.pressureBar = v }
            if let v = updates.waterTempC, v.isFinite, v > 0, v <= 110 { existing.waterTempC = v }
            if let v = updates.yieldG, v.isFinite, v > 0, v <= 100_000 { existing.yieldG = v }
            if let v = updates.extractionTimeS, v.isFinite, v > 0, v <= 100_000 { existing.extractionTimeS = v }
        }

        existing.computeDerivedMetrics()
        ChineseCoffeeAnalyzer.enrichBaristaAnalysis(&existing)
        recordStore.saveRecord(existing)
        return existing
    }

    private func applySupplementText(_ trimmedSupplement: String, to existing: inout CoffeeRecord) {
        if existing.transcript.isEmpty {
            existing.transcript = String(trimmedSupplement.prefix(Self.maxTranscriptChars))
        } else {
            existing.transcript = String((existing.transcript + "\n" + trimmedSupplement).prefix(Self.maxTranscriptChars))
        }

        let library = beanStore.loadLibrary()
        let matchedBean = beanStore.matchBean(in: trimmedSupplement)
        let parsed = ChineseCoffeeAnalyzer.extractParameters(
            transcript: trimmedSupplement,
            cameraDevice: existing.cameraDevice,
            sourceType: existing.sourceType,
            mediaKind: existing.mediaKind,
            videoPath: existing.videoPath,
            visualOverrides: nil,
            matchedBean: matchedBean,
            equipmentDefaults: library.equipment
        )

        if let v = parsed.beanName, !v.isEmpty { existing.beanName = v }
        if let v = parsed.beanRoast, !v.isEmpty { existing.beanRoast = v }
        if let v = parsed.beanWeightG { existing.beanWeightG = v }
        if let v = parsed.grindSetting, !v.isEmpty { existing.grindSetting = v }
        if let v = parsed.grinderType, !v.isEmpty { existing.grinderType = v }
        if let v = parsed.grinderModel, !v.isEmpty { existing.grinderModel = v }
        if let v = parsed.brewMethod, !v.isEmpty { existing.brewMethod = v }
        if let v = parsed.yieldG { existing.yieldG = v }
        if let v = parsed.extractionTimeS { existing.extractionTimeS = v }
        if let v = parsed.pressureBar { existing.pressureBar = v }
        if let v = parsed.waterTempC { existing.waterTempC = v }
    }

    // MARK: - Private Helpers

    private func applyVisualFallbacks(_ visual: VisualFieldReadings, to record: inout CoffeeRecord) {
        if (record.beanName ?? "").isEmpty, let v = visual.beanName, !v.isEmpty {
            record.beanName = v
        }
        if record.beanWeightG == nil, let v = visual.beanWeightG {
            record.beanWeightG = v
        }
        if (record.grindSetting ?? "").isEmpty, let v = visual.grindSetting, !v.isEmpty {
            record.grindSetting = v
        }
        if (record.grinderModel ?? "").isEmpty, let v = visual.grinderModel, !v.isEmpty {
            record.grinderModel = v
            if (record.grinderType ?? "").isEmpty {
                let builtinTokens = ["内置", "自带", "Breville", "铂富", "德龙", "格米莱", "百胜图", "Barsetto", "佩罗奇", "PELOQI"]
                if builtinTokens.contains(where: { v.localizedCaseInsensitiveContains($0) }) {
                    record.grinderType = "咖啡机自带磨豆机"
                } else {
                    record.grinderType = "额外独立磨豆机"
                }
            }
        }
        if record.pressureBar == nil, let v = visual.pressureBar {
            record.pressureBar = v
        }
        if record.waterTempC == nil, let v = visual.waterTempC {
            record.waterTempC = v
        }
        if record.yieldG == nil, let v = visual.yieldG {
            record.yieldG = v
        }
        if record.extractionTimeS == nil, let v = visual.extractionTimeS {
            record.extractionTimeS = v
        }
    }

    private func inferEspressoMachine(from record: CoffeeRecord) -> String? {
        for item in record.equipmentItems {
            let lowerID = item.id.lowercased()
            if !item.name.isEmpty && (
                item.category.contains("咖啡机")
                || lowerID.contains("machine")
                || lowerID.contains("gemilai")
            ) {
                return item.name
            }
        }
        if record.grinderType == "咖啡机自带磨豆机" {
            return record.grinderModel
        }
        return nil
    }
}
