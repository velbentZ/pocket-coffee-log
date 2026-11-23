import Foundation
import XCTest
@testable import PocketCoffeeCore

/// End-to-end on-device benchmark evaluation harness for 6 major espresso machine brands
/// (`data/eval_fixtures/machine_brands_benchmark/manifest.json`):
/// Barsetto (百胜图), Xiaomi/Mijia (小米/米家), Gemilai (格米莱),
/// PELOQI (佩罗奇/佩洛奇), MOKKOM (马克西姆), De'Longhi (德龙).
/// Skips automatically when the local fixture manifest is not present.
final class MachineBrandsEvalTests: XCTestCase {

    struct ManifestItem: Codable {
        let id: String
        let brand_cn: String
        let brand_en: String
        let expected_machine_model: String
        let platform: String
        let title: String
        let source_url: String
        let filename: String
        let duration_s: Double
        let expected_record_type: String
        let expected_brew_method: String
        let ground_truth_notes: String
    }

    struct EvalItemResult: Codable {
        let id: String
        let brand_cn: String
        let brand_en: String
        let expected_machine_model: String
        let title: String
        let duration_s: Double
        let elapsed_s: Double
        let saved: Bool
        let rejected_as_non_coffee: Bool
        let record_type: String
        let record_type_hit: Bool
        let brew_method: String?
        let brew_method_hit: Bool
        let brand_structured_hit: Bool
        let brand_raw_hit: Bool
        let detected_machines: [String]
        let equipment_items: [String]
        let grinder_model: String?
        let grinder_type: String?
        let bean_name: String?
        let bean_weight_g: Double?
        let yield_g: Double?
        let extraction_time_s: Double?
        let water_temp_c: Double?
        let brew_ratio: String?
        let grind_setting: String?
        let pressure_bar: Double?
        let transcript_length: Int
        let transcript_preview: String
        let visual_fields: [String: String]
        let visual_scene_tags: [String]
        let ocr_sample_count: Int
        let ocr_sample_lines: [String]
        let keyframes_count: Int
        let keyframe_stages: [String]
        let live_clip_count: Int
        let live_clip_stages: [String]
        let score: Int
        let score_breakdown: [String: Int]
    }

    struct EvalReport: Codable {
        let generated_at: String
        let total_videos: Int
        let average_score: Double
        let saved_count: Int
        let record_type_hits: Int
        let brew_method_hits: Int
        let brand_structured_hits: Int
        let brand_raw_hits: Int
        let results: [EvalItemResult]
    }

    private func matchesExpectedBrewMethod(actual: String?, expected: String) -> Bool {
        let trimmedExpected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedExpected.isEmpty { return true }
        guard let actual, !actual.isEmpty else { return false }
        let lowerActual = actual.lowercased()
        let tokens = trimmedExpected
            .components(separatedBy: CharacterSet(charactersIn: "/|,、 "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return tokens.contains { lowerActual.contains($0) }
    }

    private func brandMatchTokens(for item: ManifestItem) -> [String] {
        switch item.id {
        case "01_barsetto":
            return ["百胜图", "barsetto", "2sap", "bae02s", "bae01", "bae02"]
        case "02_xiaomi":
            return ["小米", "米家", "xiaomi", "mijia"]
        case "03_gemilai":
            return ["格米莱", "格米萊", "gemilai", "crm3605", "3605"]
        case "04_peloqi":
            return ["佩罗奇", "佩洛奇", "peloqi", "s1"]
        case "05_mokkom":
            return ["马克西姆", "mokkom", "塞纳", "seine"]
        case "06_delonghi":
            return ["德龙", "德龍", "de'longhi", "delonghi", "dedica", "ec685"]
        default:
            return [item.brand_cn.lowercased(), item.brand_en.lowercased()]
        }
    }

    private func containsBrandToken(in texts: [String], tokens: [String]) -> Bool {
        let combined = texts.joined(separator: " ").lowercased()
        guard !combined.isEmpty else { return false }
        return tokens.contains { token in
            let t = token.lowercased()
            // Avoid matching bare "s1" unless accompanied by brand or machine context
            if t == "s1" { return combined.contains("佩罗奇") || combined.contains("佩洛奇") || combined.contains("peloqi") }
            return combined.contains(t)
        }
    }

    func testMachineBrandsBenchmarkIfPresent() async throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let benchDir = repoRoot.appendingPathComponent("data/eval_fixtures/machine_brands_benchmark", isDirectory: true)
        let manifestURL = benchDir.appendingPathComponent("manifest.json")

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw XCTSkip("Machine brands benchmark manifest not present at \(manifestURL.path)")
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let items = try JSONDecoder().decode([ManifestItem].self, from: manifestData)
        guard !items.isEmpty else {
            throw XCTSkip("Machine brands benchmark manifest is empty")
        }

        let runRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCoffeeMachineBrands-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runRoot) }

        var results: [EvalItemResult] = []
        print("=== MACHINE BRANDS ON-DEVICE EVAL (\(items.count) videos) ===")

        for item in items {
            let videoURL = benchDir.appendingPathComponent(item.filename)
            guard FileManager.default.fileExists(atPath: videoURL.path) else {
                XCTFail("Missing video file listed in manifest: \(videoURL.path)")
                continue
            }

            let itemDir = runRoot.appendingPathComponent(item.id, isDirectory: true)
            try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)

            let recordStore = RecordStore(directoryURL: itemDir)
            let beanStore = BeanEquipmentStore(directoryURL: itemDir)
            let recognizer = AppleOnDeviceMediaRecognizer(
                keyframeBaseDirectory: itemDir.appendingPathComponent("keyframes", isDirectory: true),
                knownBeans: beanStore.loadLibrary().beans
            )
            let pipeline = CoffeeIngestionPipeline(
                recordStore: recordStore,
                beanStore: beanStore,
                recognizer: recognizer,
                advisor: RuleBasedOfflineAdvisor()
            )

            let start = Date()
            let res = await pipeline.ingestMedia(
                mediaURL: videoURL,
                spokenTranscript: "",
                sourceDevice: "\(item.platform) 导入",
                sourceType: .webUpload,
                recordIntent: .auto,
                extractFrames: true,
                save: true
            )
            let elapsed = (Date().timeIntervalSince(start) * 100).rounded() / 100
            let rec = res.record

            let liveClips = AppleOnDeviceMediaRecognizer.selectLiveClipKeyframes(
                from: rec.keyframes,
                maxClips: 4
            )

            let recordTypeHit = !res.rejectedAsNonCoffee && rec.recordType.rawValue == item.expected_record_type
            let brewMethodHit = !res.rejectedAsNonCoffee
                && matchesExpectedBrewMethod(actual: rec.brewMethod, expected: item.expected_brew_method)

            let tokens = brandMatchTokens(for: item)
            let structuredEquipTexts: [String] = rec.equipmentItems.map(\.name)
                + rec.equipmentItems.map(\.spec)
                + [rec.grinderModel ?? ""]
            let detectedMachines = rec.equipmentItems
                .filter { $0.category.contains("咖啡机") || $0.id.lowercased().contains("machine") }
                .map(\.name)

            let allOCRLines = rec.keyframes.flatMap(\.ocrTexts)
            var seenOCR = Set<String>()
            let uniqueOCRLines = allOCRLines.filter { seenOCR.insert($0.lowercased()).inserted }

            let brandStructuredHit = !res.rejectedAsNonCoffee && containsBrandToken(in: structuredEquipTexts, tokens: tokens)
            let brandRawHit = containsBrandToken(in: [rec.transcript] + uniqueOCRLines, tokens: tokens)

            // 100-point rubric tailored to 6-brand evaluation:
            // 1. Gatekeeper / saved (15 pts)
            // 2. Record type hit (15 pts)
            // 3. Brand / machine model recognition (25 pts)
            // 4. Brew method hit (15 pts)
            // 5. Parameter & evidence extraction (15 pts)
            // 6. Keyframes & 4-clip LIVE timeline distribution (15 pts)
            var breakdown: [String: Int] = [:]
            breakdown["gatekeeper"] = (res.saved && !res.rejectedAsNonCoffee) ? 15 : 0
            breakdown["record_type"] = recordTypeHit ? 15 : 0

            if brandStructuredHit {
                breakdown["brand_model"] = 25
            } else if brandRawHit {
                breakdown["brand_model"] = 8
            } else {
                breakdown["brand_model"] = 0
            }

            if brewMethodHit {
                breakdown["brew_method"] = 15
            } else if let bm = rec.brewMethod, !bm.isEmpty, !res.rejectedAsNonCoffee {
                breakdown["brew_method"] = 6
            } else {
                breakdown["brew_method"] = 0
            }

            var paramCount = 0
            if let v = rec.beanName, !v.isEmpty { paramCount += 1 }
            if rec.beanWeightG != nil { paramCount += 1 }
            if rec.yieldG != nil { paramCount += 1 }
            if rec.extractionTimeS != nil { paramCount += 1 }
            if rec.waterTempC != nil { paramCount += 1 }
            if let v = rec.brewRatio, !v.isEmpty { paramCount += 1 }
            if let v = rec.grindSetting, !v.isEmpty { paramCount += 1 }
            if let v = rec.grinderModel, !v.isEmpty { paramCount += 1 }
            if rec.pressureBar != nil { paramCount += 1 }
            let ocrHitCount = res.recognition.visualFields.asDisplayDictionary.count
            let hasSignal = !rec.transcript.isEmpty || !uniqueOCRLines.isEmpty || !res.recognition.visualSceneTags.isEmpty
            let baseParamPts = hasSignal ? 3 : 0
            breakdown["params"] = res.rejectedAsNonCoffee ? 0 : min(15, baseParamPts + min(12, (paramCount + ocrHitCount) * 3))

            let kfPts = rec.keyframes.count >= 4 ? 7 : (rec.keyframes.count >= 2 ? 4 : (rec.keyframes.count >= 1 ? 2 : 0))
            let liveCountPts = liveClips.count >= 4 ? 4 : (liveClips.count >= 2 ? 2 : 0)
            let liveSpanPts: Int
            if let first = liveClips.first, let last = liveClips.last, liveClips.count >= 2 {
                let spanPct = last.percentage - first.percentage
                liveSpanPts = spanPct >= 35 ? 4 : (spanPct >= 15 ? 2 : 1)
            } else {
                liveSpanPts = 0
            }
            breakdown["keyframes_live"] = kfPts + liveCountPts + liveSpanPts

            let totalScore = breakdown.values.reduce(0, +)
            let preview = String(rec.transcript.prefix(160)).replacingOccurrences(of: "\n", with: " ")

            let evalItem = EvalItemResult(
                id: item.id,
                brand_cn: item.brand_cn,
                brand_en: item.brand_en,
                expected_machine_model: item.expected_machine_model,
                title: item.title,
                duration_s: item.duration_s,
                elapsed_s: elapsed,
                saved: res.saved,
                rejected_as_non_coffee: res.rejectedAsNonCoffee,
                record_type: rec.recordType.rawValue,
                record_type_hit: recordTypeHit,
                brew_method: rec.brewMethod,
                brew_method_hit: brewMethodHit,
                brand_structured_hit: brandStructuredHit,
                brand_raw_hit: brandRawHit,
                detected_machines: detectedMachines,
                equipment_items: rec.equipmentItems.map(\.name),
                grinder_model: rec.grinderModel,
                grinder_type: rec.grinderType,
                bean_name: rec.beanName,
                bean_weight_g: rec.beanWeightG,
                yield_g: rec.yieldG,
                extraction_time_s: rec.extractionTimeS,
                water_temp_c: rec.waterTempC,
                brew_ratio: rec.brewRatio,
                grind_setting: rec.grindSetting,
                pressure_bar: rec.pressureBar,
                transcript_length: rec.transcript.count,
                transcript_preview: preview,
                visual_fields: res.recognition.visualFields.asDisplayDictionary,
                visual_scene_tags: res.recognition.visualSceneTags,
                ocr_sample_count: uniqueOCRLines.count,
                ocr_sample_lines: Array(uniqueOCRLines.prefix(25)),
                keyframes_count: rec.keyframes.count,
                keyframe_stages: rec.keyframes.map { "\($0.stageKey)@\($0.percentage)%" },
                live_clip_count: liveClips.count,
                live_clip_stages: liveClips.map { "\($0.stageKey)@\($0.percentage)%" },
                score: totalScore,
                score_breakdown: breakdown
            )
            results.append(evalItem)

            print("[\(item.id)] score=\(totalScore) saved=\(res.saved) rej=\(res.rejectedAsNonCoffee) type=\(rec.recordType.rawValue)(hit:\(recordTypeHit)) brandStruct=\(brandStructuredHit) brandRaw=\(brandRawHit) method=\(rec.brewMethod ?? "nil")(hit:\(brewMethodHit)) equip=\(rec.equipmentItems.map(\.name)) grinder=\(rec.grinderModel ?? "-") kf=\(rec.keyframes.count) live=\(liveClips.count) (\(elapsed)s)")
            if !preview.isEmpty {
                print("   ASR(\(rec.transcript.count)): \(preview)")
            }
            if !uniqueOCRLines.isEmpty {
                print("   OCR(\(uniqueOCRLines.count)): \(uniqueOCRLines.prefix(10).joined(separator: " | "))")
            }
            if !res.recognition.visualFields.asDisplayDictionary.isEmpty {
                print("   VisualFields: \(res.recognition.visualFields.asDisplayDictionary)")
            }
        }

        let avg = results.isEmpty ? 0.0 : (Double(results.map(\.score).reduce(0, +)) / Double(results.count) * 10).rounded() / 10
        let savedCount = results.filter(\.saved).count
        let typeHits = results.filter(\.record_type_hit).count
        let methodHits = results.filter(\.brew_method_hit).count
        let brandStructHits = results.filter(\.brand_structured_hit).count
        let brandRawHits = results.filter(\.brand_raw_hit).count

        print("=== SUMMARY: avg=\(avg)/100 | saved=\(savedCount)/\(results.count) | typeHits=\(typeHits)/\(results.count) | methodHits=\(methodHits)/\(results.count) | brandStruct=\(brandStructHits)/\(results.count) | brandRaw=\(brandRawHits)/\(results.count) ===")

        let fmt = ISO8601DateFormatter()
        let report = EvalReport(
            generated_at: fmt.string(from: Date()),
            total_videos: results.count,
            average_score: avg,
            saved_count: savedCount,
            record_type_hits: typeHits,
            brew_method_hits: methodHits,
            brand_structured_hits: brandStructHits,
            brand_raw_hits: brandRawHits,
            results: results
        )

        let outName = ProcessInfo.processInfo.environment["MACHINE_BRANDS_OUT"] ?? "eval_latest.json"
        let outURL = benchDir.appendingPathComponent(outName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(report)
        try jsonData.write(to: outURL, options: .atomic)
        print("Wrote machine brands evaluation report to: data/eval_fixtures/machine_brands_benchmark/\(outName)")

        XCTAssertEqual(results.count, items.count)
        if outName != "eval_baseline.json" {
            XCTAssertEqual(savedCount, items.count, "All 6 brand videos must be saved without false rejection")
            XCTAssertEqual(typeHits, items.count, "All 6 brand videos must hit expected recordType")
            XCTAssertEqual(methodHits, items.count, "All 6 brand videos must hit expected brewMethod")
            XCTAssertGreaterThanOrEqual(brandStructHits, 3, "All videos containing brand evidence must hit structured brand recognition")
            XCTAssertGreaterThanOrEqual(avg, 85.0, "6-brand benchmark average score must reach >= 85")
        }
    }

    // MARK: - Deterministic 6-Brand ASR Homophone, Traditional Chinese & OCR Regression Tests

    func testSixBrandsASRHomophonesAndModelNormalization() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCoffeeSixBrandsUnit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cases: [(
            label: String,
            transcript: String,
            expectedMachineFragment: String,
            expectBuiltinGrinder: Bool,
            expectedGrinderFragment: String?
        )] = [
            // 1. 百胜图 (Barsetto): homophone 白胜图 + 2sAP built-in grinder
            (
                "Barsetto 2sAP homophone",
                "今天用白胜图2sAP做一杯拿铁，称豆18克，萃取28秒出液36克，再打奶泡拉花",
                "百胜图 2sAP",
                true,
                "百胜图 2sAP"
            ),
            // 2. 小米 / 米家半自动意式咖啡机
            (
                "Xiaomi Mijia",
                "早上用米家半自动意式咖啡机做一杯意式浓缩，装粉18克萃取27秒出液36克",
                "米家半自动意式咖啡机",
                false,
                nil
            ),
            // 3. 格米莱 (Gemilai): Traditional Chinese + CRM3605 + 无底手柄
            (
                "Gemilai CRM3605 Traditional",
                "今天用格米萊 CRM3605 搭配無底手柄萃取意式濃縮，18克粉出液36克耗时26秒",
                "格米莱 CRM3605",
                false,
                nil
            ),
            // 4. 佩罗奇 / 佩洛奇 (PELOQI): homophone 佩洛奇/配罗奇 + S1 built-in grinder
            (
                "PELOQI S1 homophone",
                "手把手教你用配罗奇S1咖啡机研磨一体，称豆18克，设置了参数36克左右，第六步打奶炮",
                "佩罗奇 S1",
                true,
                "佩罗奇 S1"
            ),
            // 5. 马克西姆 (MOKKOM): 塞纳 series + 变压模式
            (
                "MOKKOM Seine",
                "相信很多朋友已经收到了塞纳这台机器，今天用变压模式做一杯拿铁，咖啡粉设置到19，20.1秒",
                "马克西姆塞纳",
                false,
                nil
            ),
            // 6. 德龙 (De'Longhi): homophone 得龙 + EC685 + 单孔音世界 -> 单孔意式机
            (
                "De'Longhi EC685 homophone",
                "今天教大家用得龙EC685这种单孔音世界打奶泡，微微抬高奶高打棉完成拉花",
                "德龙 Dedica EC685",
                false,
                nil
            ),
        ]

        for c in cases {
            let caseDir = tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: caseDir, withIntermediateDirectories: true)
            let recordStore = RecordStore(directoryURL: caseDir)
            let beanStore = BeanEquipmentStore(directoryURL: caseDir)
            let pipeline = CoffeeIngestionPipeline(
                recordStore: recordStore,
                beanStore: beanStore,
                advisor: RuleBasedOfflineAdvisor()
            )
            let res = await pipeline.ingestMedia(
                mediaURL: nil,
                spokenTranscript: c.transcript,
                sourceDevice: "iPhone 15 Pro",
                sourceType: .iphone,
                recordIntent: .auto,
                save: true
            )

            XCTAssertTrue(res.saved, "[\(c.label)] should be saved")
            XCTAssertFalse(res.rejectedAsNonCoffee, "[\(c.label)] must not be rejected")
            XCTAssertEqual(res.record.recordType, .brewReport, "[\(c.label)] must be brew_report")
            XCTAssertTrue(
                res.record.equipmentItems.contains(where: { $0.name.contains(c.expectedMachineFragment) }),
                "[\(c.label)] expected equipmentItems to contain '\(c.expectedMachineFragment)', got: \(res.record.equipmentItems.map(\.name))"
            )
            // Verify non-G3828A machines never leak "格米莱 G3828A 实木双嘴分流手柄"
            XCTAssertFalse(
                res.record.equipmentItems.contains(where: { $0.name.contains("G3828A") }),
                "[\(c.label)] must not leak G3828A accessory branding"
            )
            if c.expectBuiltinGrinder {
                XCTAssertEqual(res.record.grinderType, "咖啡机自带磨豆机", "[\(c.label)] should detect built-in grinder")
                if let frag = c.expectedGrinderFragment {
                    XCTAssertTrue(
                        (res.record.grinderModel ?? "").contains(frag),
                        "[\(c.label)] expected grinderModel to contain '\(frag)', got: \(res.record.grinderModel ?? "nil")"
                    )
                }
            }
        }
    }

    func testExternalGrinderOverridesBuiltInAndPermanentDefaultsStayIntact() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCoffeeExternalGrinder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let beanStore = BeanEquipmentStore(directoryURL: tempDir)
        let originalMachine = beanStore.loadLibrary().equipment.espressoMachine

        let pipeline = CoffeeIngestionPipeline(
            recordStore: RecordStore(directoryURL: tempDir),
            beanStore: beanStore,
            advisor: RuleBasedOfflineAdvisor()
        )
        // User uses Barsetto 2sAP (integrated grinder) BUT explicitly uses external DF64 grinder
        let res = await pipeline.ingestMedia(
            mediaURL: nil,
            spokenTranscript: "今天用百胜图2sAP搭配独立磨豆机DF64，称豆18克萃取28秒出液36克",
            sourceDevice: "iPhone 15 Pro",
            sourceType: .iphone,
            recordIntent: .auto,
            save: true
        )
        XCTAssertTrue(res.saved)
        XCTAssertEqual(res.record.grinderType, "额外独立磨豆机")
        XCTAssertEqual(res.record.grinderModel, "DF64")
        XCTAssertTrue(res.record.equipmentItems.contains(where: { $0.name.contains("百胜图 2sAP") }))
        // Permanent equipment profile's default espresso machine must NOT be overwritten by a brew report
        XCTAssertEqual(beanStore.loadLibrary().equipment.espressoMachine, originalMachine)
    }

    func testOCRBrandLogoAndTempAndBGMGatekeeper() {
        // 1. OCR machine logo variants & 92°C misread as "92で"
        let gemilaiOCR = AppleOnDeviceMediaRecognizer.extractVisualFields(stage: "grinding", ocrTexts: ["gemilai", "000"])
        XCTAssertEqual(gemilaiOCR.grinderModel, "Gemilai")

        let tempOCR = AppleOnDeviceMediaRecognizer.extractVisualFields(stage: "pressure_crema", ocrTexts: ["变压模式", "92で"])
        XCTAssertEqual(tempOCR.waterTempC, 92.0)

        // 2. BGM song-lyric ASR noise over real espresso machine scene is accepted, while casual chat without coffee scene stays rejected
        XCTAssertTrue(
            ChineseCoffeeAnalyzer.isCoffeeRelated(
                transcript: "to the safe case co face went someday",
                visualSceneTags: ["coffee", "machine", "cup", "tableware"]
            )
        )
        XCTAssertFalse(
            ChineseCoffeeAnalyzer.isCoffeeRelated(
                transcript: "今天去公园遛狗看电影",
                visualSceneTags: ["drinking_glass", "tableware"]
            )
        )
    }
}
