import Foundation
import XCTest
@testable import PocketCoffeeCore

/// End-to-end on-device benchmark evaluation harness for 10 diverse real social-platform
/// coffee videos (`data/eval_fixtures/social_benchmark/manifest.json`).
/// Skips automatically when the local fixture manifest is not present.
final class SocialBenchmarkEvalTests: XCTestCase {

    struct ManifestItem: Codable {
        let id: String
        let title: String
        let platform: String
        let source_url: String
        let category: String
        let filename: String
        let duration_s: Double
        let expected_record_type: String
        let expected_brew_method: String
        let ground_truth_notes: String
    }

    struct EvalItemResult: Codable {
        let id: String
        let title: String
        let platform: String
        let category: String
        let duration_s: Double
        let elapsed_s: Double
        let expected_record_type: String
        let expected_brew_method: String
        let saved: Bool
        let rejected_as_non_coffee: Bool
        let record_type: String
        let record_type_hit: Bool
        let brew_method: String?
        let brew_method_hit: Bool
        let bean_name: String?
        let bean_weight_g: Double?
        let yield_g: Double?
        let extraction_time_s: Double?
        let water_temp_c: Double?
        let brew_ratio: String?
        let grind_setting: String?
        let grinder_model: String?
        let pressure_bar: Double?
        let equipment_items: [String]
        let transcript_length: Int
        let transcript_preview: String
        let visual_fields: [String: String]
        let ocr_sample_count: Int
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
        let results: [EvalItemResult]
    }

    private func matchesExpectedBrewMethod(actual: String?, expected: String) -> Bool {
        let trimmedExpected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedExpected.isEmpty || trimmedExpected == "equipment_profile" || trimmedExpected == "none" {
            return true
        }
        guard let actual, !actual.isEmpty else { return false }
        let lowerActual = actual.lowercased()
        let tokens = trimmedExpected
            .components(separatedBy: CharacterSet(charactersIn: "/|,、 "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return tokens.contains { lowerActual.contains($0) }
    }

    func testSocialBenchmarkVideosIfPresent() async throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let benchDir = repoRoot.appendingPathComponent("data/eval_fixtures/social_benchmark", isDirectory: true)
        let manifestURL = benchDir.appendingPathComponent("manifest.json")

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw XCTSkip("Social benchmark manifest not present at \(manifestURL.path)")
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let items = try JSONDecoder().decode([ManifestItem].self, from: manifestData)
        guard !items.isEmpty else {
            throw XCTSkip("Social benchmark manifest is empty")
        }

        let runRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCoffeeSocialBench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runRoot) }

        var results: [EvalItemResult] = []
        print("=== SOCIAL BENCHMARK ON-DEVICE EVAL (\(items.count) videos) ===")

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

            let expectRejected = item.expected_record_type == "rejected"
            let recordTypeHit = expectRejected
                ? res.rejectedAsNonCoffee
                : (!res.rejectedAsNonCoffee && rec.recordType.rawValue == item.expected_record_type)

            let brewMethodHit: Bool
            if expectRejected {
                brewMethodHit = res.rejectedAsNonCoffee
            } else if item.expected_record_type == "equipment_profile" {
                brewMethodHit = rec.recordType == .equipmentProfile && !rec.equipmentItems.isEmpty
            } else {
                brewMethodHit = !res.rejectedAsNonCoffee
                    && matchesExpectedBrewMethod(actual: rec.brewMethod, expected: item.expected_brew_method)
            }

            // Compute 0-100 score
            var breakdown: [String: Int] = [:]
            if expectRejected {
                let s = (res.rejectedAsNonCoffee && !res.saved) ? 100 : 0
                breakdown["gatekeeper"] = s
            } else {
                // 1. Gatekeeper / saved (20 pts)
                breakdown["gatekeeper"] = (res.saved && !res.rejectedAsNonCoffee) ? 20 : 0

                // 2. Record type hit (20 pts)
                breakdown["record_type"] = recordTypeHit ? 20 : 0

                // 3. Brew method / equipment hit (20 pts)
                if item.expected_record_type == "equipment_profile" {
                    if rec.equipmentItems.count >= 2 {
                        breakdown["method_or_equip"] = 20
                    } else if rec.equipmentItems.count == 1 {
                        breakdown["method_or_equip"] = 12
                    } else {
                        breakdown["method_or_equip"] = 0
                    }
                } else {
                    if brewMethodHit {
                        breakdown["method_or_equip"] = 20
                    } else if let bm = rec.brewMethod, !bm.isEmpty, !res.rejectedAsNonCoffee {
                        breakdown["method_or_equip"] = 8
                    } else {
                        breakdown["method_or_equip"] = 0
                    }
                }

                // 4. Parameter / evidence richness (20 pts)
                if item.expected_record_type == "equipment_profile" {
                    let eqPts = min(15, rec.equipmentItems.count * 5)
                    let textPts = (!rec.transcript.isEmpty || !rec.keyframes.flatMap(\.ocrTexts).isEmpty) ? 5 : 0
                    breakdown["params"] = min(20, eqPts + textPts)
                } else {
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
                    let hasSignal = !rec.transcript.isEmpty || !rec.keyframes.flatMap(\.ocrTexts).isEmpty
                    let basePts = hasSignal ? 4 : 0
                    breakdown["params"] = res.rejectedAsNonCoffee ? 0 : min(20, basePts + min(16, (paramCount + ocrHitCount) * 3))
                }

                // 5. Keyframes & LIVE clips (20 pts)
                let kfPts: Int
                if rec.keyframes.count >= 4 {
                    kfPts = 10
                } else if rec.keyframes.count >= 2 {
                    kfPts = 6
                } else if rec.keyframes.count >= 1 {
                    kfPts = 3
                } else {
                    kfPts = 0
                }
                let liveCountPts: Int
                if liveClips.count >= 4 || (item.duration_s < 45 && liveClips.count >= 3) {
                    liveCountPts = 5
                } else if liveClips.count >= 2 {
                    liveCountPts = 3
                } else {
                    liveCountPts = 0
                }
                let liveSpanPts: Int
                if let first = liveClips.first, let last = liveClips.last, liveClips.count >= 2 {
                    let spanPct = last.percentage - first.percentage
                    liveSpanPts = spanPct >= 35 ? 5 : (spanPct >= 15 ? 3 : 1)
                } else {
                    liveSpanPts = 0
                }
                breakdown["keyframes_live"] = kfPts + liveCountPts + liveSpanPts
            }

            let totalScore = breakdown.values.reduce(0, +)
            let ocrSampleCount = rec.keyframes.reduce(0) { $0 + $1.ocrTexts.count }
            let preview = String(rec.transcript.prefix(120)).replacingOccurrences(of: "\n", with: " ")

            let evalItem = EvalItemResult(
                id: item.id,
                title: item.title,
                platform: item.platform,
                category: item.category,
                duration_s: item.duration_s,
                elapsed_s: elapsed,
                expected_record_type: item.expected_record_type,
                expected_brew_method: item.expected_brew_method,
                saved: res.saved,
                rejected_as_non_coffee: res.rejectedAsNonCoffee,
                record_type: rec.recordType.rawValue,
                record_type_hit: recordTypeHit,
                brew_method: rec.brewMethod,
                brew_method_hit: brewMethodHit,
                bean_name: rec.beanName,
                bean_weight_g: rec.beanWeightG,
                yield_g: rec.yieldG,
                extraction_time_s: rec.extractionTimeS,
                water_temp_c: rec.waterTempC,
                brew_ratio: rec.brewRatio,
                grind_setting: rec.grindSetting,
                grinder_model: rec.grinderModel,
                pressure_bar: rec.pressureBar,
                equipment_items: rec.equipmentItems.map(\.name),
                transcript_length: rec.transcript.count,
                transcript_preview: preview,
                visual_fields: res.recognition.visualFields.asDisplayDictionary,
                ocr_sample_count: ocrSampleCount,
                keyframes_count: rec.keyframes.count,
                keyframe_stages: rec.keyframes.map { "\($0.stageKey)@\($0.percentage)%" },
                live_clip_count: liveClips.count,
                live_clip_stages: liveClips.map { "\($0.stageKey)@\($0.percentage)%" },
                score: totalScore,
                score_breakdown: breakdown
            )
            results.append(evalItem)

            print("[\(item.id)] score=\(totalScore) saved=\(res.saved) rej=\(res.rejectedAsNonCoffee) type=\(rec.recordType.rawValue)(hit:\(recordTypeHit)) method=\(rec.brewMethod ?? "nil")(hit:\(brewMethodHit)) w=\(rec.beanWeightG.map { "\($0)" } ?? "-") y=\(rec.yieldG.map { "\($0)" } ?? "-") t=\(rec.extractionTimeS.map { "\($0)" } ?? "-") temp=\(rec.waterTempC.map { "\($0)" } ?? "-") kf=\(rec.keyframes.count) live=\(liveClips.count) asrLen=\(rec.transcript.count) ocr=\(ocrSampleCount) (\(elapsed)s)")
            if !preview.isEmpty {
                print("   ASR: \(preview)")
            }
            if !res.recognition.visualFields.asDisplayDictionary.isEmpty {
                print("   OCR fields: \(res.recognition.visualFields.asDisplayDictionary)")
            }
        }

        let avg = results.isEmpty ? 0.0 : (Double(results.map(\.score).reduce(0, +)) / Double(results.count) * 10).rounded() / 10
        let savedCount = results.filter(\.saved).count
        let typeHits = results.filter(\.record_type_hit).count
        let methodHits = results.filter(\.brew_method_hit).count

        print("=== SUMMARY: avg=\(avg)/100 | saved=\(savedCount)/\(results.count) | typeHits=\(typeHits)/\(results.count) | methodHits=\(methodHits)/\(results.count) ===")

        let fmt = ISO8601DateFormatter()
        let report = EvalReport(
            generated_at: fmt.string(from: Date()),
            total_videos: results.count,
            average_score: avg,
            saved_count: savedCount,
            record_type_hits: typeHits,
            brew_method_hits: methodHits,
            results: results
        )

        let outName = ProcessInfo.processInfo.environment["SOCIAL_BENCHMARK_OUT"] ?? "eval_latest.json"
        let outURL = benchDir.appendingPathComponent(outName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(report)
        try jsonData.write(to: outURL, options: .atomic)
        print("Wrote evaluation report to: data/eval_fixtures/social_benchmark/\(outName)")

        XCTAssertEqual(results.count, items.count)
        XCTAssertGreaterThanOrEqual(avg, 85.0, "10-video social benchmark average score must reach >= 85")
        XCTAssertEqual(savedCount, items.count, "All 10 real coffee videos must be saved without false rejection")
        XCTAssertEqual(typeHits, items.count, "All 10 videos must hit expected recordType")
        XCTAssertEqual(methodHits, items.count, "All 10 videos must hit expected brewMethod/equipment")
    }

    func testBilingualAndOCRAndSilentASMRGatekeeperRegression() {
        // 1. English espresso recipe equation & parameter parsing
        let enRec = ChineseCoffeeAnalyzer.extractParameters(
            transcript: "MY ESPRESSO RECIPE: 18 coffee= 36 Espresso on Breville, grind setting 12, total time: 25-30 seconds at 93°C and 9 bar."
        )
        XCTAssertEqual(enRec.brewMethod, "意式浓缩 (Espresso)")
        XCTAssertEqual(enRec.beanWeightG, 18.0)
        XCTAssertEqual(enRec.yieldG, 36.0)
        XCTAssertEqual(enRec.brewRatio, "1:2.00")
        XCTAssertEqual(enRec.extractionTimeS, 25.0)
        XCTAssertEqual(enRec.waterTempC, 93.0)
        XCTAssertEqual(enRec.pressureBar, 9.0)
        XCTAssertEqual(enRec.grindSetting, "刻度 12")

        // 2. Non-espresso brew methods (Moka Pot, AeroPress, Dirty, Flat White, Pour Over)
        XCTAssertEqual(ChineseCoffeeAnalyzer.extractParameters(transcript: "Bialetti 摩卡壺教學").brewMethod, "摩卡壶 (Moka Pot)")
        XCTAssertEqual(ChineseCoffeeAnalyzer.extractParameters(transcript: "Today we brew AeroPress with 15g coffee").brewMethod, "爱乐压 (AeroPress)")
        XCTAssertEqual(ChineseCoffeeAnalyzer.extractParameters(transcript: "Dirty到底是什么，冰镇鲜牛奶").brewMethod, "意式浓缩基底 · Dirty 咖啡")
        XCTAssertEqual(ChineseCoffeeAnalyzer.extractParameters(transcript: "做一杯澳白 flat white").brewMethod, "意式浓缩基底 · 澳白 (Flat White)")
        XCTAssertEqual(ChineseCoffeeAnalyzer.extractParameters(transcript: "V60 濾杯手沖 15g 粉 注水 225g 水溫 92°C 耗時 135秒").brewMethod, "手冲滴滤 (Pour Over)")

        // 3. Silent ASMR gatekeeper: accepts coffee visual scene, rejects non-coffee silent scene & non-coffee speech
        XCTAssertTrue(ChineseCoffeeAnalyzer.isCoffeeRelated(transcript: "", visualSceneTags: ["drinking_glass", "tableware"]))
        XCTAssertTrue(ChineseCoffeeAnalyzer.isCoffeeRelated(transcript: "", visualSceneTags: ["coffee"]))
        XCTAssertFalse(ChineseCoffeeAnalyzer.isCoffeeRelated(transcript: "", visualSceneTags: ["landscape", "tree", "sky"]))
        XCTAssertFalse(ChineseCoffeeAnalyzer.isCoffeeRelated(transcript: "今天去公园遛狗看电影", visualSceneTags: ["drinking_glass", "tableware"]))
    }
}
