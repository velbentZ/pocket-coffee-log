import Foundation
import XCTest
@testable import PocketCoffeeCore

/// Automated evaluation harness for real iPhone coffee brewing videos and transcripts.
/// Runs deterministic regression checks on real captured transcripts on every `swift test`,
/// and when `data/eval_fixtures/real_brew.mov` is present on disk, runs the full end-to-end
/// `AppleOnDeviceMediaRecognizer` + `CoffeeIngestionPipeline` evaluation scorecard.
final class RealVideoEvalTests: XCTestCase {

    func testRealIphoneTranscriptExtractionParity() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCoffeeRealTranscriptEval-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let realTranscript = "还是用这款咸芝士低因的咖啡豆 亲 别 到里的3828的厂里里面 相册 出粉18.5克 枸杞丸做一个结粉还能 布粉针 处理一下结款 压粪锤巴不平 OK 再这样子 下一个一个绿子 加一个绿子 放一下水 输液 OK我们开始吹吹 27秒初夜36.5克三16:00 油脂还是挺丰富的 好结束"

        let recordStore = RecordStore(directoryURL: tempDir)
        let beanStore = BeanEquipmentStore(directoryURL: tempDir)
        let pipeline = CoffeeIngestionPipeline(
            recordStore: recordStore,
            beanStore: beanStore,
            advisor: RuleBasedOfflineAdvisor()
        )

        let res = await pipeline.ingestMedia(
            mediaURL: nil,
            spokenTranscript: realTranscript,
            sourceDevice: "iPhone 15 Pro",
            sourceType: .iphone,
            recordIntent: .auto,
            save: true
        )

        XCTAssertTrue(res.saved)
        XCTAssertFalse(res.rejectedAsNonCoffee)
        XCTAssertEqual(res.record.recordType, .brewReport)
        XCTAssertTrue((res.record.beanName ?? "").contains("咸芝士低因"), "Expected beanName to contain 咸芝士低因, got: \(res.record.beanName ?? "nil")")
        XCTAssertEqual(res.record.beanWeightG, 18.5)
        XCTAssertEqual(res.record.yieldG, 36.5)
        XCTAssertEqual(res.record.extractionTimeS, 27.0)
        XCTAssertEqual(res.record.brewRatio, "1:1.97")
        XCTAssertTrue((res.record.grinderModel ?? "").contains("3828"))
        XCTAssertTrue((res.record.brewMethod ?? "").contains("意式"))
    }

    func testRealIphoneVideoEndToEndEvalIfPresent() async throws {
        // Locate repo root relative to this test file: ios/PocketCoffeeCore/Tests/PocketCoffeeCoreTests/RealVideoEvalTests.swift
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let videoURL = repoRoot.appendingPathComponent("data/eval_fixtures/real_brew.mov")

        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw XCTSkip("Real video fixture not present at \(videoURL.path)")
        }

        let legacyEvalDir = repoRoot.appendingPathComponent("data/eval_fixtures/last_eval_run", isDirectory: true)
        try? FileManager.default.removeItem(at: legacyEvalDir)

        let evalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCoffeeRealVideoEval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evalDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evalDir) }

        let recordStore = RecordStore(directoryURL: evalDir)
        let beanStore = BeanEquipmentStore(directoryURL: evalDir)
        let recognizer = AppleOnDeviceMediaRecognizer(
            keyframeBaseDirectory: evalDir.appendingPathComponent("keyframes", isDirectory: true),
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
            sourceDevice: "未知设备",
            sourceType: .iphone,
            recordIntent: .auto,
            extractFrames: true,
            save: true
        )
        let elapsed = Date().timeIntervalSince(start)

        let rec = res.record
        let wStr = rec.beanWeightG.map { "\($0)" } ?? "nil"
        let yStr = rec.yieldG.map { "\($0)" } ?? "nil"
        let tStr = rec.extractionTimeS.map { "\($0)" } ?? "nil"
        print("=== REAL VIDEO AUTO-EVAL SCORECARD (\(String(format: "%.1fs", elapsed))) ===")
        print("Saved: \(res.saved) | Rejected: \(res.rejectedAsNonCoffee) | Type: \(rec.recordType.rawValue) | Status: \(rec.status)")
        print("Bean: \(rec.beanName ?? "nil") | Weight: \(wStr) | Grind: \(rec.grindSetting ?? "nil") | Grinder: \(rec.grinderModel ?? "nil")")
        print("Method: \(rec.brewMethod ?? "nil") | Yield: \(yStr) | Time: \(tStr) | Ratio: \(rec.brewRatio ?? "nil")")
        print("Transcript: \(rec.transcript)")
        print("Keyframes (\(rec.keyframes.count)):")
        for (i, kf) in rec.keyframes.enumerated() {
            let fileName = kf.imagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "nil"
            print("  [\(i + 1)] t=\(kf.timestampS)s (\(kf.percentage)%) key=\(kf.stageKey) label=\(kf.stage) fields=\(kf.detectedFields) img=\(fileName)")
        }

        // Core quality assertions
        XCTAssertTrue(res.saved)
        XCTAssertEqual(rec.recordType, .brewReport)
        XCTAssertEqual(rec.cameraDevice, "iPhone 15 Pro", "Should auto-detect real camera model from QuickTime metadata")
        XCTAssertTrue((rec.beanName ?? "").contains("咸芝士低因"), "Bean name should be recognized from video/speech")
        XCTAssertEqual(rec.beanWeightG, 18.5, "Grounds/bean weight 18.5g should be captured")
        XCTAssertEqual(rec.yieldG, 36.5, "Yield 36.5g should be captured")
        XCTAssertEqual(rec.extractionTimeS, 27.0, "Extraction time 27s should be captured")
        XCTAssertGreaterThanOrEqual(rec.keyframes.count, 5, "Should capture rich multi-scene keyframes")
        XCTAssertTrue(rec.keyframes.contains(where: { $0.percentage >= 85 }), "Must include final finished-cup scene (>=85%)")

        // Xiaohongshu carousel exportable cards verification (must NEVER drop to 1 cover-only card)
        let exportable = SandboxPathResolver.exportableXiaohongshuKeyframes(for: rec)
        XCTAssertGreaterThanOrEqual(exportable.count, 5, "Xiaohongshu carousel must keep >=5 keyframe cards (+1 cover >= 6 cards)")
        for kf in exportable {
            let path = try XCTUnwrap(kf.imagePath)
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
            XCTAssertGreaterThan(bytes, 1024, "Keyframe JPEG must be non-empty: \(path)")
        }

        // Auto-save recognized coffee bean + bean close-up photo into BeanEquipmentStore
        let storedBeans = beanStore.loadLibrary().beans
        let autoSavedBean = try XCTUnwrap(
            storedBeans.first(where: { $0.fullName.contains("咸芝士低因") }),
            "Recognized bean from brew report must automatically be saved into BeanEquipmentStore"
        )
        XCTAssertEqual(autoSavedBean.shotsCount, 1)
        XCTAssertEqual(autoSavedBean.remainingWeightG, 231.5, accuracy: 0.1)
        let coverPath = try XCTUnwrap(autoSavedBean.coverImagePath, "Auto-saved bean must attach bean/scale close-up photo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: coverPath), "Bean cover photo must exist on disk: \(coverPath)")

        // Auto-import explicitly mentioned accessories from brew report into equipment profile
        let autoAccessories = beanStore.loadLibrary().equipment.accessories
        XCTAssertGreaterThanOrEqual(autoAccessories.count, 2, "Brew report mentioning 布粉针/压粉锤/3828 must auto-import accessories")

        // Verify action-driven LIVE clip selection picks real brewing moments (dosing/WDT/tamping + extraction/pouring + final cup)
        let selectedLiveClips = AppleOnDeviceMediaRecognizer.selectLiveClipKeyframes(from: exportable, maxClips: 4)
        print("Selected LIVE clips (\(selectedLiveClips.count)):")
        for (i, kf) in selectedLiveClips.enumerated() {
            print("  LIVE[\(i + 1)] t=\(kf.timestampS)s (\(kf.percentage)%) key=\(kf.stageKey) label=\(kf.stage)")
        }
        XCTAssertEqual(selectedLiveClips.count, 4)
        let selectedKeys = Set(selectedLiveClips.map(\.stageKey))
        XCTAssertTrue(
            !selectedKeys.isDisjoint(with: ["dose_weigh", "wdt_distribute", "leveler_flatten", "tamping"]),
            "LIVE clips must include dosing/WDT/tamping action, got: \(selectedKeys)"
        )
        XCTAssertTrue(
            selectedKeys.contains("pressure_crema"),
            "LIVE clips must include espresso extraction/pouring action, got: \(selectedKeys)"
        )
        XCTAssertTrue(
            selectedLiveClips.allSatisfy { $0.timestampS >= 3.0 },
            "LIVE clips must skip boring 0% intro frames when action scenes exist"
        )

        // Verify 2.5s dynamic close-up clip export actually produces playable clips on the real iPhone video
        let clipsDir = evalDir.appendingPathComponent("closeup_clips", isDirectory: true)
        let exportedClips = await AppleOnDeviceMediaRecognizer.exportDynamicCloseUpClips(
            videoURL: videoURL,
            keyframes: selectedLiveClips,
            outputDirectory: clipsDir,
            maxClips: 4,
            clipDurationS: 2.5
        )
        XCTAssertEqual(exportedClips.count, 4, "2.5s dynamic close-up exporter must produce 4 clips from real iPhone video")
        for clipURL in exportedClips {
            let attrs = try FileManager.default.attributesOfItem(atPath: clipURL.path)
            let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
            XCTAssertGreaterThan(bytes, 50_000, "Exported close-up clip must be a real playable video: \(clipURL.lastPathComponent)")
        }
    }

    func testDefaultWaterTempPersistsAndIsPreservedDuringBrewAccessoryAutoImport() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCoffeeEquipPersist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = BeanEquipmentStore(directoryURL: tempDir)
        var profile = store.loadLibrary().equipment
        profile.defaultWaterTempC = 91.5
        _ = store.saveEquipmentProfile(profile)

        // Reload from disk to verify persistence
        let reloaded = BeanEquipmentStore(directoryURL: tempDir)
        XCTAssertEqual(reloaded.loadLibrary().equipment.defaultWaterTempC, 91.5, accuracy: 0.01)

        // Run a normal brew report mentioning WDT + tamper; accessories should auto-import while 91.5°C is preserved
        let recordStore = RecordStore(directoryURL: tempDir)
        let pipeline = CoffeeIngestionPipeline(
            recordStore: recordStore,
            beanStore: reloaded,
            advisor: RuleBasedOfflineAdvisor()
        )
        let res = await pipeline.ingestMedia(
            mediaURL: nil,
            spokenTranscript: "今天用耶加雪菲18克，用布粉针打散结块，再用压粉锤压实，萃取28秒出液36克",
            sourceDevice: "iPhone 15 Pro",
            sourceType: .iphone,
            recordIntent: .brewReport,
            save: true
        )
        XCTAssertTrue(res.saved)
        let afterEquip = reloaded.loadLibrary().equipment
        XCTAssertEqual(afterEquip.defaultWaterTempC, 91.5, accuracy: 0.01, "Auto-importing accessories must not reset defaultWaterTempC")
        XCTAssertGreaterThanOrEqual(afterEquip.accessories.count, 2, "Mentioned 布粉针 & 压粉锤 must auto-import into equipment accessories")
    }

    func testAutoUpsertBeanFromBrewRecordDeduplicatesAndDeletes() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCoffeeBeanAutoUpsert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let coverFile = tempDir.appendingPathComponent("bean_closeup.jpg")
        try Data(repeating: 0xAA, count: 2048).write(to: coverFile)

        let store = BeanEquipmentStore(directoryURL: tempDir)
        let removedSamples = store.removeSeededSampleBeans()
        XCTAssertEqual(removedSamples, 3)
        XCTAssertTrue(store.loadLibrary().beans.isEmpty)

        let record1 = CoffeeRecord(
            beanName: "咸芝士低因",
            beanRoast: "中深烘",
            beanWeightG: 18.5,
            grindSetting: "刻度 14",
            grinderModel: "格米莱 G3828A",
            yieldG: 36.5,
            extractionTimeS: 27.0,
            brewRatio: "1:1.97",
            flavorNotes: ["咸芝士", "黑巧"],
            keyframes: [
                KeyframeObservation(
                    stageKey: "bean_bag",
                    stage: "咖啡豆特写",
                    percentage: 8,
                    timestampS: 4.0,
                    imagePath: coverFile.path,
                    extracted: true
                ),
            ]
        )

        let first = try XCTUnwrap(store.upsertBeanFromBrewRecord(record1))
        XCTAssertEqual(first.fullName, "咸芝士低因")
        XCTAssertEqual(first.shotsCount, 1)
        XCTAssertEqual(first.remainingWeightG, 231.5, accuracy: 0.01)
        XCTAssertEqual(first.coverImagePath, coverFile.path)
        XCTAssertTrue(first.goldenRecipeNote.contains("18.5g -> 36.5g"))

        // Second shot with the same bean should deduct & increment shotsCount, NOT duplicate
        let second = try XCTUnwrap(store.upsertBeanFromBrewRecord(record1))
        XCTAssertEqual(store.loadLibrary().beans.count, 1)
        XCTAssertEqual(second.shotsCount, 2)
        XCTAssertEqual(second.remainingWeightG, 213.0, accuracy: 0.01)

        // Single delete & batch multi-delete work
        store.deleteBean(id: second.id)
        XCTAssertTrue(store.loadLibrary().beans.isEmpty)

        let b1 = store.addOrUpdateBean(BeanEntry(id: "b1", fullName: "测试豆1"))
        let b2 = store.addOrUpdateBean(BeanEntry(id: "b2", fullName: "测试豆2"))
        let b3 = store.addOrUpdateBean(BeanEntry(id: "b3", fullName: "测试豆3"))
        let batchRemoved = store.deleteBeans(ids: [b1.id, b3.id])
        XCTAssertEqual(batchRemoved, 2)
        XCTAssertEqual(store.loadLibrary().beans.map(\.id), [b2.id])
    }

    func testBeanEntryExpiryDateBackwardCompatAndFreshnessAndEdit() throws {
        // 1. Legacy JSON without expiry_date or cover_image_path must decode cleanly
        let legacyJSON = """
        {
          "id": "bean-legacy",
          "short_aliases": ["旧豆"],
          "full_name": "耶加雪菲旧档",
          "roast_level": "浅度烘焙",
          "roast_date": "2026-11-01",
          "initial_weight_g": 250,
          "remaining_weight_g": 200,
          "recommended_grind": "刻度 15",
          "flavor_tags": ["柑橘"],
          "golden_recipe_note": "",
          "shots_count": 2
        }
        """
        let decoded = try JSONDecoder().decode(BeanEntry.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.fullName, "耶加雪菲旧档")
        XCTAssertEqual(decoded.expiryDate, "")
        XCTAssertNil(decoded.coverImagePath)

        // 2. Editing remaining weight, initial weight, roastDate, and expiryDate persists across reload
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCoffeeBeanEdit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = BeanEquipmentStore(directoryURL: tempDir)
        var edited = decoded
        edited.remainingWeightG = 142.5
        edited.initialWeightG = 250
        edited.roastDate = "2026-11-05"
        edited.expiryDate = "2027-02-05"
        _ = store.addOrUpdateBean(edited)

        let reloadedStore = BeanEquipmentStore(directoryURL: tempDir)
        let saved = try XCTUnwrap(reloadedStore.loadLibrary().beans.first(where: { $0.id == "bean-legacy" }))
        XCTAssertEqual(saved.remainingWeightG, 142.5, accuracy: 0.01)
        XCTAssertEqual(saved.roastDate, "2026-11-05")
        XCTAssertEqual(saved.expiryDate, "2027-02-05")

        // 3. Freshness status across resting / peak / near-expiry / expired windows
        let ref = try XCTUnwrap(BeanEntry.parseISODate("2026-11-22"))
        let restingBean = BeanEntry(fullName: "新烘豆", roastDate: "2026-11-19", expiryDate: "2027-02-19")
        XCTAssertEqual(restingBean.freshnessInfo(referenceDate: ref)?.level, .resting)

        let peakBean = BeanEntry(fullName: "赏味期豆", roastDate: "2026-11-05", expiryDate: "2027-02-05")
        XCTAssertEqual(peakBean.freshnessInfo(referenceDate: ref)?.level, .peak)

        let nearExpiryBean = BeanEntry(fullName: "临期豆", roastDate: "2026-10-01", expiryDate: "2026-11-29")
        XCTAssertEqual(nearExpiryBean.freshnessInfo(referenceDate: ref)?.level, .fading)

        let expiredBean = BeanEntry(fullName: "过期豆", roastDate: "2026-08-01", expiryDate: "2026-11-15")
        XCTAssertEqual(expiredBean.freshnessInfo(referenceDate: ref)?.level, .expired)
    }

    func testBeanBagOCRLabelParsingWithRoastAndExpiryDatesAndCoverPhoto() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCoffeeBeanBagOCR-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let photoFile = tempDir.appendingPathComponent("bag.jpg")
        try Data(repeating: 0xCC, count: 2048).write(to: photoFile)

        let store = BeanEquipmentStore(directoryURL: tempDir)

        // 1. Explicit production date + expiry date + weight + cover image
        let ocrText1 = """
        咸芝士低因 意式拼配
        中深烘焙 净含量 250g
        生产日期: 2026.11.05
        保质期至: 2027.05.05
        风味描述: 黑巧 焦糖 奶油
        """
        let preview1 = store.parseBeanLabelPreview(ocrText1, coverImagePath: photoFile.path)
        XCTAssertEqual(preview1.roastDate, "2026-11-05")
        XCTAssertEqual(preview1.expiryDate, "2027-05-05")
        XCTAssertEqual(preview1.initialWeightG, 250.0, accuracy: 0.01)
        XCTAssertEqual(preview1.coverImagePath, photoFile.path)
        XCTAssertTrue(preview1.roastLevel.contains("深"))

        // 2. Relative shelf-life (保质期 6个月 / 赏味期 90天)
        let ocrText2 = "埃塞俄比亚 耶加雪菲 水洗 浅烘 200g 烘焙日期 2026-11-10 保质期 6个月"
        let preview2 = store.parseBeanLabelPreview(ocrText2)
        XCTAssertEqual(preview2.roastDate, "2026-11-10")
        XCTAssertEqual(preview2.expiryDate, "2027-05-10")
        XCTAssertEqual(preview2.initialWeightG, 200.0, accuracy: 0.01)

        let ocrText3 = "巴拿马 瑰夏 日晒 100g 烘焙日期 2026-11-10 赏味期 90天"
        let preview3 = store.parseBeanLabelPreview(ocrText3)
        XCTAssertEqual(preview3.roastDate, "2026-11-10")
        XCTAssertEqual(preview3.expiryDate, "2027-02-08")
    }

    func testBeanBagScanDuplicateDetectionAndThreeMergeModes() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCoffeeBeanMerge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let newBagPhoto = tempDir.appendingPathComponent("new_bag.jpg")
        try Data(repeating: 0xDD, count: 2048).write(to: newBagPhoto)

        let store = BeanEquipmentStore(directoryURL: tempDir)
        _ = store.removeSeededSampleBeans()

        // Existing bean created earlier from a brew video
        let existing = store.addOrUpdateBean(BeanEntry(
            id: "bean-cheese-existing",
            shortAliases: ["咸芝士低因"],
            fullName: "咸芝士低因",
            roastLevel: "中度烘焙",
            roastDate: "2026-11-01",
            expiryDate: "",
            initialWeightG: 250,
            remainingWeightG: 231.5,
            recommendedGrind: "刻度 14",
            flavorTags: ["咸芝士"],
            goldenRecipeNote: "18.5g -> 36.5g",
            shotsCount: 1
        ))

        let ocrText = """
        咸芝士低因 意式拼配
        中深烘焙 净含量 250g
        生产日期: 2026.11.20
        保质期至: 2027.05.20
        风味描述: 黑巧 焦糖
        """
        let scanned = store.parseBeanLabelPreview(ocrText, coverImagePath: newBagPhoto.path)
        let matched = try XCTUnwrap(
            store.findMatchingBeanForScan(rawText: ocrText, parsedBean: scanned),
            "Must detect existing bean via fuzzy/alias match even when OCR fullName has extra words"
        )
        XCTAssertEqual(matched.id, existing.id)

        // Mode 1: Supplement current bag (preserve weight & shotsCount, update photo & dates)
        let supplemented = BeanEquipmentStore.mergeScannedBean(scanned, with: matched, mode: .supplementCurrent)
        XCTAssertEqual(supplemented.id, existing.id)
        XCTAssertEqual(supplemented.remainingWeightG, 231.5, accuracy: 0.01)
        XCTAssertEqual(supplemented.shotsCount, 1)
        XCTAssertEqual(supplemented.roastDate, "2026-11-20")
        XCTAssertEqual(supplemented.expiryDate, "2027-05-20")
        XCTAssertEqual(supplemented.coverImagePath, newBagPhoto.path)
        XCTAssertTrue(supplemented.flavorTags.contains("咸芝士"))
        XCTAssertTrue(supplemented.flavorTags.contains("黑巧"))

        // Mode 2: Restock new bag (add 250g to remaining weight, keep shotsCount)
        let restocked = BeanEquipmentStore.mergeScannedBean(scanned, with: matched, mode: .restockNewBag)
        XCTAssertEqual(restocked.id, existing.id)
        XCTAssertEqual(restocked.shotsCount, 1)
        XCTAssertEqual(restocked.remainingWeightG, 481.5, accuracy: 0.01)
        XCTAssertEqual(restocked.initialWeightG, 481.5, accuracy: 0.01)
        XCTAssertEqual(restocked.roastDate, "2026-11-20")
        XCTAssertEqual(restocked.expiryDate, "2027-05-20")

        // Mode 3: Create separate new bean
        let separate = BeanEquipmentStore.mergeScannedBean(scanned, with: matched, mode: .createSeparate)
        XCTAssertNotEqual(separate.id, existing.id)
        XCTAssertEqual(separate.remainingWeightG, 250.0, accuracy: 0.01)
        XCTAssertEqual(separate.shotsCount, 0)
        _ = store.addOrUpdateBean(separate)
        XCTAssertEqual(store.loadLibrary().beans.count, 2)
    }

    func testMultiPhotoFrontBackBeanBagOCRMergesNameAndDatesAndMachinePhotoPersists() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCoffeeMultiPhotoBag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let frontPhoto = tempDir.appendingPathComponent("front.jpg")
        let backPhoto = tempDir.appendingPathComponent("back.jpg")
        let machinePhoto = tempDir.appendingPathComponent("machine.jpg")
        try Data(repeating: 0x11, count: 2048).write(to: frontPhoto)
        try Data(repeating: 0x22, count: 2048).write(to: backPhoto)
        try Data(repeating: 0x33, count: 2048).write(to: machinePhoto)

        let store = BeanEquipmentStore(directoryURL: tempDir)
        let frontOCR = "咸芝士低因 意式拼配\n中深烘焙\n风味描述: 黑巧 焦糖 奶油"
        let backOCR = "净含量 250g\n生产日期: 2026.11.12\n保质期至: 2027.05.12"
        let combined = "\(frontOCR)\n\(backOCR)"

        let savedBean = store.parseBeanLabelText(
            combined,
            coverImagePath: frontPhoto.path,
            photoPaths: [frontPhoto.path, backPhoto.path]
        )
        XCTAssertEqual(savedBean.roastDate, "2026-11-12")
        XCTAssertEqual(savedBean.expiryDate, "2027-05-12")
        XCTAssertEqual(savedBean.initialWeightG, 250.0, accuracy: 0.01)
        XCTAssertEqual(savedBean.allPhotoPaths.count, 2)
        XCTAssertEqual(savedBean.coverImagePath, frontPhoto.path)

        var profile = store.loadLibrary().equipment
        profile.machinePhotoPath = machinePhoto.path
        _ = store.saveEquipmentProfile(profile)

        let reloaded = BeanEquipmentStore(directoryURL: tempDir)
        XCTAssertEqual(reloaded.loadLibrary().equipment.machinePhotoPath, machinePhoto.path)
        let reloadedBean = try XCTUnwrap(reloaded.loadLibrary().beans.first(where: { $0.id == savedBean.id }))
        XCTAssertEqual(reloadedBean.allPhotoPaths.count, 2)
    }

    func testSandboxPathRebaseSurvivesAppReinstallContainerRotation() throws {
        // Simulate an iOS app reinstall where the container UUID changes from OLD-UUID to NEW-UUID.
        let newContainer = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCoffeeNewContainer-\(UUID().uuidString)", isDirectory: true)
        let newDocs = newContainer.appendingPathComponent("Documents", isDirectory: true)
        let newCaches = newContainer.appendingPathComponent("Library/Caches", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: newContainer) }

        let newMediaFile = newDocs.appendingPathComponent("PocketCoffeeData/Media/media-123.mov")
        let newLegacyCacheKf = newCaches.appendingPathComponent("PocketCoffeeKeyframes/run1/kf_1.jpg")
        let newPersistentKf = newDocs.appendingPathComponent("PocketCoffeeData/Keyframes/run1/kf_2.jpg")

        try FileManager.default.createDirectory(at: newMediaFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newLegacyCacheKf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newPersistentKf.deletingLastPathComponent(), withIntermediateDirectories: true)

        try Data("fake-video".utf8).write(to: newMediaFile)
        try Data(repeating: 0xFF, count: 2048).write(to: newLegacyCacheKf)
        try Data(repeating: 0xEE, count: 2048).write(to: newPersistentKf)

        // Build a record containing stale OLD-UUID paths (just like coffee_records.json before reinstall)
        let staleRecord = CoffeeRecord(
            mediaKind: .video,
            videoPath: "/var/mobile/Containers/Data/Application/OLD-UUID-1111/Documents/PocketCoffeeData/Media/media-123.mov",
            mediaURL: "/var/mobile/Containers/Data/Application/OLD-UUID-1111/Documents/PocketCoffeeData/Media/media-123.mov",
            keyframes: [
                KeyframeObservation(
                    stageKey: "scale_dose",
                    stage: "称重豆量",
                    percentage: 10,
                    timestampS: 4.0,
                    imagePath: "/var/mobile/Containers/Data/Application/OLD-UUID-1111/Library/Caches/PocketCoffeeKeyframes/run1/kf_1.jpg",
                    extracted: true
                ),
                KeyframeObservation(
                    stageKey: "yield_timer",
                    stage: "成品出杯",
                    percentage: 92,
                    timestampS: 45.0,
                    imagePath: "/var/mobile/Containers/Data/Application/OLD-UUID-1111/Documents/PocketCoffeeData/Keyframes/run1/kf_2.jpg",
                    extracted: true
                ),
            ]
        )

        let healed = SandboxPathResolver.resolveRecordPaths(
            staleRecord,
            documentsDirectory: newDocs,
            cachesDirectory: newCaches
        )
        XCTAssertEqual(healed.videoPath, newMediaFile.path)
        XCTAssertEqual(healed.mediaURL, newMediaFile.path)

        let exportable = SandboxPathResolver.exportableXiaohongshuKeyframes(
            for: staleRecord,
            documentsDirectory: newDocs,
            cachesDirectory: newCaches
        )
        XCTAssertEqual(exportable.count, 2, "All legacy Caches and persistent Documents keyframes must survive container UUID rotation")
        XCTAssertEqual(exportable[0].imagePath, newLegacyCacheKf.path)
        XCTAssertEqual(exportable[1].imagePath, newPersistentKf.path)
    }
}
