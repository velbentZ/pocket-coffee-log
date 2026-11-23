import XCTest
@testable import PocketCoffeeCore

final class AnalyzerAndStoreTests: XCTestCase {

    private var tempDirs: [URL] = []

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocket-coffee-tests-\(UUID().uuidString)", isDirectory: true)
        tempDirs.append(url)
        return url
    }

    override func tearDownWithError() throws {
        for url in tempDirs {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirs.removeAll()
    }

    private let fullBrewTranscript =
        "今天咖啡豆用的是埃塞俄比亚花魁7.0日晒中浅烘，咖啡豆称重十八点五克，"
        + "用的是额外独立磨豆机 Niche Zero，研磨度调到刻度 14.5 格。"
        + "今天做的是 SOE 单一产地意式浓缩，水温 93 度，萃取压力稳定在酒八，"
        + "萃取时间用了二十九秒，最后初夜是三十六克。"

    private let equipmentIntroTranscript =
        "今天先介绍一下我们咖啡角的器具，这是轰炸机压粉锤，四桨布粉器，磁吸接粉环，"
        + "还有 58mm 双嘴手柄和丸型滤纸，旁边是桌面吸尘器和电子秤。"

    // MARK: - Chinese numeral parsing

    func testChineseNumeralParsing() {
        XCTAssertEqual(ChineseCoffeeAnalyzer.parseChineseOrDouble("18.5"), 18.5)
        XCTAssertEqual(ChineseCoffeeAnalyzer.parseChineseOrDouble(" 36 "), 36)
        XCTAssertEqual(ChineseCoffeeAnalyzer.parseChineseOrDouble("十八"), 18)
        XCTAssertEqual(ChineseCoffeeAnalyzer.parseChineseOrDouble("二十八"), 28)
        XCTAssertEqual(ChineseCoffeeAnalyzer.parseChineseOrDouble("三十六"), 36)
        XCTAssertEqual(ChineseCoffeeAnalyzer.parseChineseOrDouble("十五"), 15)
        XCTAssertEqual(ChineseCoffeeAnalyzer.parseChineseOrDouble("十"), 10)
        XCTAssertEqual(ChineseCoffeeAnalyzer.parseChineseOrDouble("九点五"), 9.5)
        XCTAssertEqual(ChineseCoffeeAnalyzer.parseChineseOrDouble("十点五"), 10.5)
        XCTAssertEqual(ChineseCoffeeAnalyzer.parseChineseOrDouble("三点二五"), 3.25)
        XCTAssertEqual(ChineseCoffeeAnalyzer.parseChineseOrDouble("两"), 2)
        XCTAssertEqual(ChineseCoffeeAnalyzer.parseChineseOrDouble("零"), 0)
        XCTAssertNil(ChineseCoffeeAnalyzer.parseChineseOrDouble("abc"))
        XCTAssertNil(ChineseCoffeeAnalyzer.parseChineseOrDouble(""))
        // Python parity: the leading-十 branch ignores trailing unit characters.
        XCTAssertEqual(ChineseCoffeeAnalyzer.parseChineseOrDouble("十八克"), 18)
    }

    // MARK: - Espresso extraction & ASR homophones

    func testCompleteEspressoExtractionWithASRHomophones() {
        let record = ChineseCoffeeAnalyzer.extractParameters(
            transcript: fullBrewTranscript,
            cameraDevice: "DJI Osmo Pocket 4 Pro",
            sourceType: .djiPocket
        )
        XCTAssertEqual(record.recordType, .brewReport)
        XCTAssertEqual(record.beanName, "埃塞俄比亚花魁7.0日晒中浅烘")
        XCTAssertEqual(record.beanRoast, "中浅烘焙")
        XCTAssertEqual(record.beanWeightG, 18.5)
        XCTAssertEqual(record.grindSetting, "刻度 14.5 格")
        XCTAssertEqual(record.grinderType, "额外独立磨豆机")
        XCTAssertEqual(record.grinderModel, "Niche Zero")
        XCTAssertEqual(record.brewMethod, "SOE 单一产地意式浓缩")
        XCTAssertEqual(record.waterTempC, 93)
        // 「酒八」→ 9bar, 「初夜」→ 出液, 「二十九秒」→ 29s
        XCTAssertEqual(record.pressureBar, 9)
        XCTAssertEqual(record.yieldG, 36)
        XCTAssertEqual(record.extractionTimeS, 29)
        XCTAssertEqual(record.brewRatio, "1:1.95")
        XCTAssertEqual(record.status, "complete")
        XCTAssertTrue(record.missingFields.isEmpty)
        XCTAssertTrue(record.extractionDiagnosis.contains("黄金萃取区间命中"))
        XCTAssertEqual(record.flavorNotes, ["佛手柑", "热带百香果", "草莓果酱", "奶油太妃糖尾韵"])
        XCTAssertEqual(record.flavorProfile.sweetness, 8.8, accuracy: 1e-9)
        XCTAssertEqual(record.suggestions.count, 3)
        XCTAssertEqual(record.timelineEvents.count, 5)
        XCTAssertTrue(record.xiaohongshuCopy.contains("今日萃取档案"))
        XCTAssertTrue(record.wechatCopy.contains("出杯报告"))
        XCTAssertTrue(record.wechatCopy.contains("29s @ 9.0 bar"))
    }

    func testGemilai3828BuiltInGrinderRecognition() {
        let transcript =
            "今天用格米莱3828自带磨豆机做一杯意式浓缩，咖啡豆称重 18 克，"
            + "研磨度调到刻度 14，萃取时间 28 秒，出液是 36 克，萃取压力 9 bar。"
        let record = ChineseCoffeeAnalyzer.extractParameters(transcript: transcript)
        XCTAssertEqual(record.grinderType, "咖啡机自带磨豆机")
        XCTAssertEqual(record.grinderModel, "格米莱 G3828A (云象One 内置60mm平刀磨豆机)")
        XCTAssertEqual(record.beanWeightG, 18)
        XCTAssertEqual(record.yieldG, 36)
        XCTAssertEqual(record.extractionTimeS, 28)
        XCTAssertEqual(record.pressureBar, 9)
        XCTAssertEqual(record.brewMethod, "意式浓缩 (Espresso)")
        XCTAssertEqual(record.brewRatio, "1:2.00")
        XCTAssertEqual(record.status, "complete")
    }

    func testColdBrewExtraction() {
        let transcript =
            "今天做一壶冷萃咖啡，咖啡豆用的是巴拿马翡翠庄园绿标瑰夏浅烘，"
            + "咖啡豆称重 45 克，用的是额外独立磨豆机 DF64，研磨度调到刻度 58 格，"
            + "注水出液量是 405 毫升，冰箱低温萃取时间 12 小时。"
        let record = ChineseCoffeeAnalyzer.extractParameters(transcript: transcript)
        XCTAssertEqual(record.brewMethod, "冷萃咖啡 (Cold Brew)")
        XCTAssertEqual(record.beanWeightG, 45)
        XCTAssertEqual(record.yieldG, 405)
        XCTAssertEqual(record.extractionTimeS, 43200)
        XCTAssertEqual(record.pressureBar, 1)
        XCTAssertEqual(record.grinderModel, "DF64")
        XCTAssertEqual(record.beanRoast, "浅度烘焙")
        XCTAssertEqual(record.status, "complete")
        XCTAssertTrue(record.extractionDiagnosis.contains("低温慢速浸泡约 12.0 小时"))
        XCTAssertTrue(record.wechatCopy.contains("12.0h"))
        XCTAssertEqual(record.flavorNotes, ["茉莉花香", "水蜜桃汁", "柑橘蜜甜", "丝滑冷冽尾韵"])
    }

    // MARK: - Missing-field detection (no fabricated metrics)

    func testMissingFieldDetectionDoesNotFabricateMetrics() {
        let record = ChineseCoffeeAnalyzer.extractParameters(transcript: "今天用花魁做一杯意式浓缩，味道不错。")
        XCTAssertEqual(record.status, "needs_info")
        let missing = Set(record.missingFields.map(\.field))
        XCTAssertTrue(missing.isSuperset(of: [
            "bean_weight_g", "grind_setting", "grinder_type", "grinder_model",
            "yield_g", "extraction_time_s", "pressure_bar",
        ]))
        XCTAssertFalse(missing.contains("bean_name"))
        XCTAssertFalse(missing.contains("brew_method"))
        XCTAssertNil(record.beanWeightG)
        XCTAssertNil(record.yieldG)
        XCTAssertNil(record.extractionTimeS)
        XCTAssertTrue(record.extractionDiagnosis.contains("尚未完整采集"))
        XCTAssertTrue(record.extractionDiagnosis.contains("不会虚构"))
        XCTAssertTrue(record.extractionDiagnosis.contains("咖啡豆称重 (g)"))
        XCTAssertEqual(record.flavorNotes, ["待补全实测参数", "支持语音/手动一键补全"])
        XCTAssertEqual(record.suggestions.count, 2)
    }

    func testPartiallyCapturedMetricsAreReportedHonestly() {
        let record = ChineseCoffeeAnalyzer.extractParameters(
            transcript: "今天用花魁做意式浓缩，咖啡豆称重 18 克，出液 36 克。"
        )
        XCTAssertEqual(record.beanWeightG, 18)
        XCTAssertEqual(record.yieldG, 36)
        XCTAssertNil(record.extractionTimeS)
        XCTAssertEqual(record.status, "needs_info")
        XCTAssertTrue(record.extractionDiagnosis.contains("粉重 18.0g"))
        XCTAssertTrue(record.extractionDiagnosis.contains("出液 36.0g"))
        XCTAssertFalse(record.extractionDiagnosis.contains("耗时"))
        XCTAssertTrue(record.missingFields.map(\.field).contains("extraction_time_s"))
    }

    func testFastExtractionSuggestsFinerGrind() {
        let record = ChineseCoffeeAnalyzer.extractParameters(
            transcript: "今天用花魁做意式浓缩，咖啡豆称重 18 克，研磨度刻度 14，出液 36 克，萃取时间 18 秒，压力 9 bar。"
        )
        XCTAssertEqual(record.extractionTimeS, 18)
        XCTAssertEqual(record.grindSetting, "刻度 14")
        XCTAssertTrue(record.extractionDiagnosis.contains("流速偏快（18s 萃出 36.0g，粉液比 1:2.0）"))
        XCTAssertTrue(record.suggestions[0].contains("【研磨度调细】"))
        XCTAssertTrue(record.suggestions[0].contains("往细调 0.5 ~ 1.0 格"))
        XCTAssertEqual(record.flavorProfile.acidity, 8.7, accuracy: 1e-9)
        XCTAssertEqual(record.flavorProfile.body, 6.5, accuracy: 1e-9)
    }

    func testSlowExtractionSuggestsCoarserGrind() {
        let record = ChineseCoffeeAnalyzer.extractParameters(
            transcript: "今天用花魁做意式浓缩，咖啡豆称重 18 克，研磨度刻度 14，出液 36 克，萃取时间 40 秒，压力 9 bar。"
        )
        XCTAssertEqual(record.extractionTimeS, 40)
        XCTAssertTrue(record.extractionDiagnosis.contains("流速偏慢（耗时 40s，压力 9.0 bar）"))
        XCTAssertTrue(record.suggestions[0].contains("【研磨度调粗】"))
        XCTAssertTrue(record.suggestions[0].contains("或将粉量减少 0.5g 至 17.5g"))
        XCTAssertEqual(record.flavorProfile.acidity, 6.2, accuracy: 1e-9)
        XCTAssertEqual(record.flavorProfile.body, 8.9, accuracy: 1e-9)
    }

    // MARK: - Equipment introduction classification

    func testEquipmentIntroductionClassification() {
        let introRecord = ChineseCoffeeAnalyzer.extractParameters(transcript: equipmentIntroTranscript)
        XCTAssertEqual(introRecord.recordType, .equipmentProfile)
        XCTAssertEqual(introRecord.status, "complete")
        XCTAssertTrue(introRecord.missingFields.isEmpty)
        XCTAssertEqual(introRecord.brewMethod, "常驻设备与器具档案补充")
        XCTAssertEqual(introRecord.beanName, "居家咖啡机 · 全套器具建档")
        XCTAssertEqual(introRecord.grinderType, "咖啡机自带磨豆机")
        XCTAssertEqual(introRecord.grinderModel, "格米莱 G3828A (云象One 研磨一体咖啡机)")
        XCTAssertTrue(introRecord.extractionDiagnosis.contains("建档完成"))
        XCTAssertTrue(introRecord.extractionDiagnosis.contains("7 类常驻器具"))
        XCTAssertEqual(introRecord.suggestions.count, 3)
        XCTAssertEqual(introRecord.timelineEvents.count, 4)
        XCTAssertEqual(introRecord.timelineEvents.first?.stage, "主力咖啡机识别")
        XCTAssertTrue(introRecord.xiaohongshuCopy.contains("设备大盘点"))
        XCTAssertTrue(introRecord.xiaohongshuCopy.contains("• MHW-3BOMBER"))
        XCTAssertTrue(introRecord.wechatCopy.contains("主力机"))
        let itemIDs = Set(introRecord.equipmentItems.map(\.id))
        XCTAssertTrue(itemIDs.isSuperset(of: [
            "eq-mhw-tamper", "eq-distributor", "eq-dosing-wdt", "eq-portafilter",
            "eq-filter-paper", "eq-vacuum-cleaner", "eq-cups-scale",
        ]))

        // An actual brew with measured parameters is never an equipment introduction.
        let brewRecord = ChineseCoffeeAnalyzer.extractParameters(transcript: fullBrewTranscript)
        XCTAssertEqual(brewRecord.recordType, .brewReport)
        XCTAssertFalse(ChineseCoffeeAnalyzer.isEquipmentIntroduction(transcript: fullBrewTranscript, record: brewRecord))

        // Brew metrics override keyword hits.
        var metricsRecord = CoffeeRecord(transcript: equipmentIntroTranscript)
        metricsRecord.beanWeightG = 18
        XCTAssertFalse(ChineseCoffeeAnalyzer.isEquipmentIntroduction(transcript: equipmentIntroTranscript, record: metricsRecord))

        // Empty transcript is not an introduction.
        XCTAssertFalse(ChineseCoffeeAnalyzer.isEquipmentIntroduction(transcript: "", record: CoffeeRecord()))

        // Explicitly typed equipment records stay classified.
        var typed = CoffeeRecord(transcript: "随便一段话")
        typed.recordType = .equipmentProfile
        XCTAssertTrue(ChineseCoffeeAnalyzer.isEquipmentIntroduction(transcript: "随便一段话", record: typed))
    }

    func testExtractEquipmentItemsFallbackAndDeduplication() {
        let fallback = ChineseCoffeeAnalyzer.extractEquipmentItems(from: "随便聊聊今天的天气")
        XCTAssertEqual(fallback.count, 5)
        XCTAssertEqual(fallback.first?.id, "eq-gemilai-g3828a")
        XCTAssertTrue(ChineseCoffeeAnalyzer.extractEquipmentItems(from: "").isEmpty)

        let matched = ChineseCoffeeAnalyzer.extractEquipmentItems(from: "介绍一下压粉锤和布粉器")
        XCTAssertEqual(matched.map(\.id), ["eq-mhw-tamper", "eq-distributor"])
    }

    func testRelabelKeyframesForEquipmentProfile() {
        let keyframes = (0..<5).map { idx in
            KeyframeObservation(
                stageKey: "P\(idx + 1)",
                stage: "萃取阶段 \(idx + 1)",
                presetBadge: "P\(idx + 1) 旧标签",
                percentage: idx * 20,
                timestampS: Double(idx) * 10,
                visualDescription: "旧画面描述"
            )
        }
        let relabeled = ChineseCoffeeAnalyzer.relabelKeyframesForEquipmentProfile(keyframes, items: [])
        XCTAssertEqual(relabeled.count, 5)
        XCTAssertEqual(relabeled.map(\.presetBadge), [
            "E1 压粉与布粉台", "E2 配件与清洁工具", "E3 咖啡机与手柄",
            "E4 咖啡角与常驻豆", "E4 咖啡角与常驻豆",
        ])
        XCTAssertEqual(relabeled[0].stage, "MHW-3BOMBER 自动回弹压粉锤 · 布粉器 · 实木压粉底座")
        XCTAssertTrue(relabeled[2].visualDescription.contains("格米莱 G3828A"))
        // Non-label fields are preserved.
        XCTAssertEqual(relabeled[1].timestampS, 10)
        XCTAssertEqual(relabeled[1].percentage, 20)
        XCTAssertEqual(relabeled[1].stageKey, "P2")
    }

    // MARK: - Visual overrides, bean library & equipment defaults

    func testBeanLibraryMatchAndEquipmentDefaultsAndVisualOverrides() {
        let store = BeanEquipmentStore(directoryURL: makeTempDir())
        let matchedBean = store.matchBean(in: "今天用花魁")
        XCTAssertEqual(matchedBean?.id, "bean-huakui")

        let record = ChineseCoffeeAnalyzer.extractParameters(
            transcript: "今天做一杯意式浓缩",
            visualOverrides: VisualFieldReadings(beanWeightG: 18.5, pressureBar: 9.2, yieldG: 37, extractionTimeS: 29),
            matchedBean: matchedBean,
            equipmentDefaults: EquipmentProfile()
        )
        XCTAssertEqual(record.beanName, "埃塞俄比亚 罕贝拉 花魁 7.0 日晒")
        XCTAssertEqual(record.beanRoast, "中浅烘焙")
        // With complete metrics the espresso branch re-derives flavor notes from the
        // bean name (花魁), overriding the library tags — same as core/analyzer.py.
        XCTAssertEqual(record.flavorNotes, ["佛手柑", "热带百香果", "草莓果酱", "奶油太妃糖尾韵"])
        XCTAssertEqual(record.grinderType, "额外独立磨豆机")
        XCTAssertEqual(record.grinderModel, "Niche Zero (63mm 锥刀)")
        XCTAssertEqual(record.waterTempC, 93)
        XCTAssertEqual(record.beanWeightG, 18.5)
        XCTAssertEqual(record.yieldG, 37)
        XCTAssertEqual(record.pressureBar, 9.2)
        XCTAssertEqual(record.extractionTimeS, 29)
        XCTAssertEqual(record.brewRatio, "1:2.00")
        // Grind auto-fill from the bean library is gated off in the Python pipeline
        // (`_auto_fill_bean_grind` is never set), so grind stays missing here.
        XCTAssertNil(record.grindSetting)
        XCTAssertTrue(record.missingFields.map(\.field).contains("grind_setting"))

        // Without core metrics the honest-diagnosis branch keeps the library tags.
        let incomplete = ChineseCoffeeAnalyzer.extractParameters(
            transcript: "今天做一杯意式浓缩",
            matchedBean: matchedBean
        )
        XCTAssertEqual(incomplete.flavorNotes, ["佛手柑", "热带百香果", "草莓果酱", "奶油太妃糖"])
    }

    func testVisualOverridesDoNotClobberTranscriptValues() {
        let record = ChineseCoffeeAnalyzer.extractParameters(
            transcript: fullBrewTranscript,
            visualOverrides: VisualFieldReadings(beanWeightG: 99, yieldG: 999)
        )
        XCTAssertEqual(record.beanWeightG, 18.5)
        XCTAssertEqual(record.yieldG, 36)
    }

    // MARK: - Bean library: seeding, shorthand matching, label parsing

    func testSeededLibraryAndShorthandMatching() {
        let store = BeanEquipmentStore(directoryURL: makeTempDir())
        let library = store.loadLibrary()
        XCTAssertEqual(library.beans.count, 3)
        XCTAssertEqual(library.equipment.espressoMachine, "格米莱 G3828A (云象One)")
        XCTAssertEqual(store.matchBean(in: "今天用花魁")?.id, "bean-huakui")
        XCTAssertEqual(store.matchBean(in: "冲一杯瑰夏")?.id, "bean-geisha")
        XCTAssertEqual(store.matchBean(in: "来一杯哥伦比亚")?.id, "bean-paraiso")
        XCTAssertEqual(store.matchBean(in: "花魁7.0")?.id, "bean-huakui")
        XCTAssertEqual(store.matchBean(in: "bean-geisha")?.id, "bean-geisha")
        XCTAssertNil(store.matchBean(in: "完全无关的文字"))
        XCTAssertNil(store.matchBean(in: "   "))
    }

    func testParseBeanLabelReusesExistingBeanID() {
        let store = BeanEquipmentStore(directoryURL: makeTempDir())
        let label = "巴拿马 翡翠庄园 绿标瑰夏 水洗 浅烘 风味：茉莉花、水蜜桃、蜂蜜 净含量 200g 烘焙日期 2026-11-15"
        let bean = store.parseBeanLabelText(label)
        XCTAssertEqual(bean.id, "bean-geisha")
        XCTAssertEqual(bean.fullName, "巴拿马 翡翠庄园 绿标瑰夏 水洗")
        XCTAssertEqual(bean.roastLevel, "浅度烘焙")
        XCTAssertEqual(bean.roastDate, "2026-11-15")
        XCTAssertEqual(bean.initialWeightG, 200)
        XCTAssertEqual(bean.remainingWeightG, 200)
        XCTAssertEqual(bean.recommendedGrind, "刻度 13.5 格")
        // Python parity: the explicit 风味 capture runs to end of line and its token
        // filter only drops 烘焙/日期/weight tokens, so 净含量 and the ISO date survive.
        XCTAssertEqual(bean.flavorTags, ["茉莉花", "水蜜桃", "蜂蜜", "净含量", "2026-11-15"])
        XCTAssertTrue(bean.shortAliases.contains("绿标瑰夏"))
        XCTAssertTrue(bean.shortAliases.contains("翡翠庄园"))
        XCTAssertTrue(bean.goldenRecipeNote.contains("1:2.2"))
        // Updated in place, not duplicated.
        XCTAssertEqual(store.loadLibrary().beans.count, 3)
    }

    func testParseBeanLabelWithRemainingWeightAndChineseDate() {
        let store = BeanEquipmentStore(directoryURL: makeTempDir())
        let label = "云南 保山 日晒 中烘 净含量 250g 剩余 120.5g 烘焙日期 2026年10月1日"
        let bean = store.parseBeanLabelText(label)
        XCTAssertEqual(bean.fullName, "云南 保山 日晒")
        XCTAssertEqual(bean.roastLevel, "中度烘焙")
        XCTAssertEqual(bean.roastDate, "2026-10-01")
        XCTAssertEqual(bean.initialWeightG, 250)
        XCTAssertEqual(bean.remainingWeightG, 120.5)
        XCTAssertEqual(bean.recommendedGrind, "刻度 14.2 格")
        XCTAssertEqual(bean.flavorTags, ["柑橘", "花香", "焦糖甜感"])
        XCTAssertEqual(store.loadLibrary().beans.count, 4)
        XCTAssertEqual(store.loadLibrary().beans.first?.id, bean.id)
        // Scanning the same bag again updates the same entry.
        let rescanned = store.parseBeanLabelText(label)
        XCTAssertEqual(rescanned.id, bean.id)
        XCTAssertEqual(store.loadLibrary().beans.count, 4)
    }

    func testParseEmptyBeanLabelCreatesDefaultCard() {
        let store = BeanEquipmentStore(directoryURL: makeTempDir())
        let bean = store.parseBeanLabelText("   ")
        XCTAssertEqual(bean.fullName, "未命名豆袋")
        XCTAssertEqual(bean.initialWeightG, 250)
        XCTAssertEqual(bean.remainingWeightG, 250)
        XCTAssertEqual(bean.flavorTags, ["柑橘", "坚果"])
        XCTAssertTrue(bean.id.hasPrefix("bean-scan-"))
    }

    // MARK: - Dose deduction

    func testDeductBeanDoseClampsAndPersists() {
        let dir = makeTempDir()
        let store = BeanEquipmentStore(directoryURL: dir)
        let first = store.deductBeanDose(beanName: "花魁", doseG: 18.5)
        XCTAssertEqual(first?.id, "bean-huakui")
        XCTAssertEqual(first?.remainingWeightG, 166.5)
        XCTAssertEqual(first?.shotsCount, 4)

        let second = store.deductBeanDose(beanName: "花魁", doseG: 999)
        XCTAssertEqual(second?.remainingWeightG, 0)
        XCTAssertEqual(second?.shotsCount, 5)

        XCTAssertNil(store.deductBeanDose(beanName: "不存在的豆子", doseG: 18))
        XCTAssertNil(store.deductBeanDose(beanName: "", doseG: 18))

        let reloaded = BeanEquipmentStore(directoryURL: dir)
        XCTAssertEqual(reloaded.matchBean(in: "花魁")?.remainingWeightG, 0)
        XCTAssertEqual(reloaded.matchBean(in: "花魁")?.shotsCount, 5)
    }

    // MARK: - Equipment profile merging

    func testEquipmentMergeIsDuplicateFreeAndPersists() {
        let dir = makeTempDir()
        let store = BeanEquipmentStore(directoryURL: dir)
        let items = ChineseCoffeeAnalyzer.extractEquipmentItems(from: "介绍一下压粉锤和布粉器")
        XCTAssertEqual(items.count, 2)

        let profile1 = store.updateEquipmentFromIntro(
            equipmentItems: items,
            grinderType: "咖啡机自带磨豆机",
            grinderModel: "格米莱 G3828A (云象One 内置60mm平刀磨豆机)",
            espressoMachine: "格米莱 G3828A (云象One)"
        )
        XCTAssertEqual(profile1.accessories.count, 2)
        XCTAssertEqual(profile1.defaultGrinderType, "咖啡机自带磨豆机")
        XCTAssertEqual(profile1.defaultGrinderModel, "格米莱 G3828A (云象One 内置60mm平刀磨豆机)")

        // Re-introducing the same accessories must not duplicate them.
        let profile2 = store.updateEquipmentFromIntro(equipmentItems: items)
        XCTAssertEqual(profile2.accessories.count, 2)
        XCTAssertEqual(profile2.defaultGrinderType, "咖啡机自带磨豆机")

        // Partial updates keep stored spec/role/category when incoming fields are empty.
        let partial = EquipmentItem(id: "eq-mhw-tamper", name: "自定义恒力压粉锤", category: "")
        let profile3 = store.updateEquipmentFromIntro(equipmentItems: [partial])
        XCTAssertEqual(profile3.accessories.count, 2)
        let tamper = profile3.accessories.first { $0.id == "eq-mhw-tamper" }
        XCTAssertEqual(tamper?.name, "自定义恒力压粉锤")
        XCTAssertEqual(tamper?.spec, "58.35mm 精密螺纹底座 · 30lbs 恒压自动回弹")
        XCTAssertEqual(tamper?.category, "压粉器具 (自动回弹)")

        // New accessories append without disturbing existing ones.
        let scale = EquipmentItem(id: "eq-cups-scale", name: "咖啡秤", category: "称量与出品杯具")
        let profile4 = store.updateEquipmentFromIntro(equipmentItems: [scale])
        XCTAssertEqual(profile4.accessories.count, 3)

        let reloaded = BeanEquipmentStore(directoryURL: dir)
        let persisted = reloaded.loadLibrary().equipment
        XCTAssertEqual(persisted.accessories.count, 3)
        XCTAssertEqual(persisted.espressoMachine, "格米莱 G3828A (云象One)")
        XCTAssertEqual(Set(persisted.accessories.map(\.id)).count, 3)
    }

    func testAddOrUpdateBeanAndSaveEquipmentProfile() {
        let store = BeanEquipmentStore(directoryURL: makeTempDir())
        let newBean = BeanEntry(
            id: "bean-test-new",
            shortAliases: ["测试豆"],
            fullName: "测试庄园 水洗 中浅烘",
            roastLevel: "中浅烘焙",
            roastDate: "2026-11-01",
            initialWeightG: 250,
            remainingWeightG: 250
        )
        let inserted = store.addOrUpdateBean(newBean)
        XCTAssertEqual(inserted.id, "bean-test-new")
        XCTAssertEqual(store.loadLibrary().beans.count, 4)
        XCTAssertEqual(store.loadLibrary().beans.first?.id, "bean-test-new")
        XCTAssertEqual(store.matchBean(in: "来一杯测试豆")?.id, "bean-test-new")

        var updated = inserted
        updated.remainingWeightG = 200
        updated.shotsCount = 2
        _ = store.addOrUpdateBean(updated)
        XCTAssertEqual(store.loadLibrary().beans.count, 4)
        XCTAssertEqual(store.matchBean(in: "测试豆")?.remainingWeightG, 200)
        XCTAssertEqual(store.matchBean(in: "测试豆")?.shotsCount, 2)

        var profile = EquipmentProfile()
        profile.espressoMachine = "测试咖啡机"
        profile.defaultWaterTempC = 94
        let saved = store.saveEquipmentProfile(profile)
        XCTAssertEqual(saved.espressoMachine, "测试咖啡机")
        XCTAssertEqual(store.loadLibrary().equipment.defaultWaterTempC, 94)
    }

    // MARK: - RecordStore persistence

    func testRecordStoreSeedsSamplesNewestFirst() throws {
        let dir = makeTempDir()
        let store = RecordStore(directoryURL: dir)
        let records = store.listRecords()
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map(\.id), [
            "brew-20261115-095012-p3",
            "brew-20261115-094210-p4p",
            "brew-20261114-211500-cb",
        ])

        let r1 = try XCTUnwrap(store.getRecord(id: "brew-20261115-094210-p4p"))
        XCTAssertEqual(r1.recordType, .brewReport)
        XCTAssertEqual(r1.sourceType, .djiPocket)
        XCTAssertEqual(r1.cameraDevice, "DJI Osmo Pocket 4 Pro")
        XCTAssertEqual(r1.beanWeightG, 18.5)
        XCTAssertEqual(r1.yieldG, 37)
        XCTAssertEqual(r1.extractionTimeS, 29)
        XCTAssertEqual(r1.pressureBar, 9.2)
        XCTAssertEqual(r1.waterTempC, 93)
        XCTAssertEqual(r1.grindSetting, "刻度 14.5 格")
        XCTAssertEqual(r1.grinderModel, "Niche Zero")
        XCTAssertEqual(r1.brewMethod, "SOE 单一产地意式浓缩")
        XCTAssertEqual(r1.brewRatio, "1:2.00")
        XCTAssertEqual(r1.status, "complete")

        let r2 = try XCTUnwrap(store.getRecord(id: "brew-20261115-095012-p3"))
        XCTAssertEqual(r2.status, "needs_info")
        XCTAssertEqual(r2.missingFields.map(\.field), ["grind_setting", "pressure_bar"])
        XCTAssertEqual(r2.grinderModel, "Breville 铂富内置锥刀磨豆机")
        XCTAssertEqual(r2.brewMethod, "意式浓缩基底 · 冰拿铁/热拿铁")

        let r3 = try XCTUnwrap(store.getRecord(id: "brew-20261114-211500-cb"))
        XCTAssertEqual(r3.brewMethod, "冷萃咖啡 (Cold Brew)")
        XCTAssertEqual(r3.extractionTimeS, 43200)
        XCTAssertEqual(r3.pressureBar, 1)
        XCTAssertEqual(r3.yieldG, 405)
        XCTAssertEqual(r3.status, "complete")

        // JSON on disk uses the backend's snake_case keys and round-trips.
        let fileURL = dir.appendingPathComponent("coffee_records.json")
        let data = try Data(contentsOf: fileURL)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(raw.count, 3)
        XCTAssertNotNil(raw[0]["created_at"])
        XCTAssertNotNil(raw[0]["record_type"])
        let decoded = try JSONDecoder().decode([CoffeeRecord].self, from: data)
        XCTAssertEqual(decoded.count, 3)

        // A second store instance loads the same file without re-seeding.
        let reloaded = RecordStore(directoryURL: dir)
        XCTAssertEqual(reloaded.listRecords().map(\.id), records.map(\.id))
    }

    func testRecordStoreUpsertDeleteAndRoundTrip() throws {
        let dir = makeTempDir()
        let store = RecordStore(directoryURL: dir)
        var record = ChineseCoffeeAnalyzer.extractParameters(transcript: "今天做一杯意式浓缩，咖啡豆称重 18 克，出液 36 克，萃取时间 28 秒，压力 9 bar。")
        record.id = "brew-test-upsert"
        record.createdAt = "2026-11-20 10:00:00"
        store.saveRecord(record)

        XCTAssertEqual(store.listRecords().count, 4)
        XCTAssertEqual(store.listRecords().first?.id, "brew-test-upsert")
        XCTAssertEqual(store.getRecord(id: "brew-test-upsert")?.beanWeightG, 18)

        // Upsert replaces by id instead of appending.
        record.transcript = "补充：研磨度刻度 14"
        record.grindSetting = "刻度 14"
        record.computeDerivedMetrics()
        store.saveRecord(record)
        XCTAssertEqual(store.listRecords().count, 4)
        XCTAssertEqual(store.getRecord(id: "brew-test-upsert")?.grindSetting, "刻度 14")

        store.deleteRecord(id: "brew-test-upsert")
        XCTAssertEqual(store.listRecords().count, 3)
        XCTAssertNil(store.getRecord(id: "brew-test-upsert"))

        let reloaded = RecordStore(directoryURL: dir)
        XCTAssertEqual(reloaded.listRecords().count, 3)
        XCTAssertNil(reloaded.getRecord(id: "brew-test-upsert"))
        XCTAssertNotNil(reloaded.getRecord(id: "brew-20261115-094210-p4p"))
    }

    func testRecordStoreConcurrentSavesAreSafe() {
        let store = RecordStore(directoryURL: makeTempDir())
        let iterations = 20
        DispatchQueue.concurrentPerform(iterations: iterations) { idx in
            var record = CoffeeRecord(transcript: "并发写入测试 \(idx)")
            record.id = "brew-concurrent-\(idx)"
            record.createdAt = String(format: "2026-11-21 12:00:%02d", idx)
            store.saveRecord(record)
        }
        let records = store.listRecords()
        XCTAssertEqual(records.count, 3 + iterations)
        for idx in 0..<iterations {
            XCTAssertNotNil(store.getRecord(id: "brew-concurrent-\(idx)"))
        }
        // Newest first ordering holds across concurrent inserts.
        XCTAssertEqual(records.first?.id, "brew-concurrent-19")
        let timestamps = records.map(\.createdAt)
        XCTAssertEqual(timestamps, timestamps.sorted(by: >))
    }
}
