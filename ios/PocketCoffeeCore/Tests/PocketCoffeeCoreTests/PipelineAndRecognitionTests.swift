import Foundation
import XCTest
@testable import PocketCoffeeCore

private struct StubMediaRecognizer: MediaRecognizing {
    var stubbedAudioTranscript: String = ""
    var stubbedVisualFields: VisualFieldReadings = VisualFieldReadings()
    var stubbedKeyframes: [KeyframeObservation] = []

    func detectMediaKind(for url: URL?) -> MediaKind {
        AppleOnDeviceMediaRecognizer().detectMediaKind(for: url)
    }

    func recognizeMedia(
        mediaURL: URL?,
        spokenTranscript: String,
        sourceDevice: String,
        hintOverrides: VisualFieldReadings?,
        extractFrames: Bool
    ) async -> RecognitionOutput {
        let kind = detectMediaKind(for: mediaURL)
        let combined: String
        let trimmedSpoken = spokenTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if stubbedAudioTranscript.isEmpty {
            combined = trimmedSpoken
        } else if trimmedSpoken.isEmpty {
            combined = stubbedAudioTranscript
        } else {
            combined = "\(stubbedAudioTranscript) \(trimmedSpoken)"
        }

        let mergedVisual = (hintOverrides ?? VisualFieldReadings()).merged(overridingWith: stubbedVisualFields)
        let frames: [KeyframeObservation] = (kind == .video && extractFrames) ? stubbedKeyframes : []

        return RecognitionOutput(
            mediaKind: kind,
            mediaPath: mediaURL?.path,
            sourceDevice: sourceDevice,
            audioTranscript: stubbedAudioTranscript,
            transcript: combined,
            speechSegments: [],
            visualFields: mergedVisual,
            keyframes: frames,
            durationS: kind == .text ? nil : 42.0
        )
    }
}

final class PipelineAndRecognitionTests: XCTestCase {
    private var tempDir: URL!
    private var recordStore: RecordStore!
    private var beanStore: BeanEquipmentStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCoffeeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        recordStore = RecordStore(directoryURL: tempDir)
        beanStore = BeanEquipmentStore(directoryURL: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testAudioOnlyRecognitionSkipsVideoKeyframes() async {
        let audioURL = tempDir.appendingPathComponent("voice_memo.m4a")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data())

        let recognizer = AppleOnDeviceMediaRecognizer(keyframeBaseDirectory: tempDir)
        XCTAssertEqual(recognizer.detectMediaKind(for: audioURL), .audio)
        XCTAssertEqual(recognizer.detectMediaKind(for: nil), .text)
        XCTAssertEqual(recognizer.detectMediaKind(for: tempDir.appendingPathComponent("clip.mp4")), .video)

        let output = await recognizer.recognizeMedia(
            mediaURL: audioURL,
            spokenTranscript: "今天用耶加雪菲，粉量18克，液重36克，萃取28秒",
            sourceDevice: "语音备忘录",
            hintOverrides: nil,
            extractFrames: true
        )

        XCTAssertEqual(output.mediaKind, .audio)
        XCTAssertTrue(output.keyframes.isEmpty, "Audio-only media must not emit video keyframes")
        XCTAssertTrue(output.transcript.contains("耶加雪菲"))
    }

    func testStandaloneRecognizeMediaDoesNotSaveToRecordStore() async {
        let stub = StubMediaRecognizer(
            stubbedAudioTranscript: "今天做一杯意式浓缩，粉量18.5克",
            stubbedVisualFields: VisualFieldReadings(yieldG: 37.0, extractionTimeS: 27.0),
            stubbedKeyframes: [
                KeyframeObservation(stageKey: "scale_dose", stage: "电子秤称豆画面", percentage: 15, timestampS: 6.0),
            ]
        )
        let pipeline = CoffeeIngestionPipeline(
            recordStore: recordStore,
            beanStore: beanStore,
            recognizer: stub,
            advisor: RuleBasedOfflineAdvisor()
        )

        let beforeCount = recordStore.listRecords().count
        let videoURL = tempDir.appendingPathComponent("espresso.mov")
        let output = await pipeline.recognizeMedia(
            mediaURL: videoURL,
            spokenTranscript: "",
            sourceDevice: "iPhone 手机录制"
        )

        XCTAssertEqual(output.mediaKind, .video)
        XCTAssertEqual(output.keyframes.count, 1)
        XCTAssertEqual(output.visualFields.yieldG, 37.0)
        XCTAssertEqual(recordStore.listRecords().count, beforeCount, "Standalone recognizeMedia must not persist any record")
    }

    func testGenerateReportMergesVisualOCRAndTranscriptDeductsBeanAndSavesBrewReport() async {
        let initialBean = BeanEntry(
            id: "bean-yirga-test",
            shortAliases: ["耶加", "耶加雪菲"],
            fullName: "埃塞俄比亚 耶加雪菲 水洗",
            roastLevel: "中浅烘焙",
            initialWeightG: 200.0,
            remainingWeightG: 200.0
        )
        _ = beanStore.addOrUpdateBean(initialBean)

        let recognition = RecognitionOutput(
            mediaKind: .video,
            mediaPath: tempDir.appendingPathComponent("brew.mp4").path,
            sourceDevice: "iPhone 手机录制",
            audioTranscript: "今天用耶加雪菲做一杯意式浓缩，独立磨豆机 Niche Zero，刻度 14",
            transcript: "今天用耶加雪菲做一杯意式浓缩，独立磨豆机 Niche Zero，刻度 14",
            speechSegments: [],
            visualFields: VisualFieldReadings(
                beanWeightG: 18.0,
                pressureBar: 9.0,
                waterTempC: 93.0,
                yieldG: 36.0,
                extractionTimeS: 28.0
            ),
            keyframes: [
                KeyframeObservation(stageKey: "scale_dose", stage: "电子秤称豆画面", percentage: 15, timestampS: 5.0),
            ],
            durationS: 38.0
        )

        let pipeline = CoffeeIngestionPipeline(
            recordStore: recordStore,
            beanStore: beanStore,
            recognizer: StubMediaRecognizer(),
            advisor: RuleBasedOfflineAdvisor()
        )

        let result = await pipeline.generateReport(
            from: recognition,
            sourceType: .iphone,
            recordIntent: .brewReport,
            save: true
        )

        XCTAssertTrue(result.saved)
        XCTAssertEqual(result.record.recordType, .brewReport)
        XCTAssertEqual(result.record.beanName, "埃塞俄比亚 耶加雪菲 水洗")
        XCTAssertEqual(result.record.beanWeightG, 18.0)
        XCTAssertEqual(result.record.yieldG, 36.0)
        XCTAssertEqual(result.record.extractionTimeS, 28.0)
        XCTAssertEqual(result.record.pressureBar, 9.0)
        XCTAssertEqual(result.record.brewRatio, "1:2.00")
        XCTAssertEqual(result.advisorBackend, "rule_based_offline")
        XCTAssertFalse(result.record.extractionDiagnosis.isEmpty)

        // Verify persistence in RecordStore
        let stored = recordStore.getRecord(id: result.record.id)
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.beanWeightG, 18.0)

        // Verify bean dose deduction
        XCTAssertNotNil(result.deductedBean)
        if let updatedBean = result.deductedBean {
            XCTAssertEqual(updatedBean.remainingWeightG, 182.0, accuracy: 0.01)
        }
    }

    func testIngestMediaEquipmentIntroductionPersistsToBeanEquipmentStore() async {
        let introTranscript = "今天给大家介绍一下我的居家咖啡器具，这是一台格米莱 G3828A 咖啡机，自带磨豆机，还有压粉锤、布粉器和无底手柄一整套制作的工具。"
        let stub = StubMediaRecognizer(
            stubbedAudioTranscript: introTranscript,
            stubbedKeyframes: [
                KeyframeObservation(stageKey: "scale_dose", stage: "电子秤称豆画面", percentage: 15, timestampS: 4.0),
                KeyframeObservation(stageKey: "grinder_dial", stage: "磨豆机刻度盘特写", percentage: 35, timestampS: 10.0),
            ]
        )

        let pipeline = CoffeeIngestionPipeline(
            recordStore: recordStore,
            beanStore: beanStore,
            recognizer: stub,
            advisor: RuleBasedOfflineAdvisor()
        )

        let result = await pipeline.ingestMedia(
            mediaURL: tempDir.appendingPathComponent("equipment_tour.mov"),
            spokenTranscript: "",
            sourceDevice: "iPhone 手机录制",
            sourceType: .iphone,
            recordIntent: .auto,
            save: true
        )

        XCTAssertTrue(result.saved)
        XCTAssertEqual(result.record.recordType, .equipmentProfile)
        XCTAssertFalse(result.record.equipmentItems.isEmpty)
        XCTAssertNotNil(result.updatedEquipment)
        XCTAssertNil(result.deductedBean, "Equipment profile should not deduct bean dose")

        let persistedLibrary = beanStore.loadLibrary()
        XCTAssertFalse(persistedLibrary.equipment.accessories.isEmpty)
    }

    func testOfflineAndFoundationModelAdvisorsWorkWithoutErrors() async {
        var recordA = CoffeeRecord(
            beanName: "耶加雪菲",
            beanWeightG: 18.0,
            grindSetting: "刻度 14",
            grinderType: "额外独立磨豆机",
            grinderModel: "Niche Zero",
            brewMethod: "意式浓缩",
            yieldG: 36.0,
            extractionTimeS: 28.0,
            pressureBar: 9.0,
            waterTempC: 93.0
        )
        recordA.computeDerivedMetrics()

        let recognition = RecognitionOutput(
            mediaKind: .text,
            transcript: "耶加雪菲 18g 液重 36g 28秒 9bar"
        )

        let offlineAdvisor = RuleBasedOfflineAdvisor()
        XCTAssertTrue(offlineAdvisor.isAvailable)
        XCTAssertEqual(offlineAdvisor.backendName, "rule_based_offline")
        await offlineAdvisor.enhance(record: &recordA, recognition: recognition)
        XCTAssertFalse(recordA.extractionDiagnosis.isEmpty)
        XCTAssertFalse(recordA.xiaohongshuCopy.isEmpty)
        XCTAssertFalse(recordA.wechatCopy.isEmpty)

        var recordB = CoffeeRecord(
            beanName: "耶加雪菲",
            beanWeightG: 18.0,
            grindSetting: "刻度 14",
            grinderType: "额外独立磨豆机",
            grinderModel: "Niche Zero",
            brewMethod: "意式浓缩",
            yieldG: 36.0,
            extractionTimeS: 28.0,
            pressureBar: 9.0,
            waterTempC: 93.0
        )
        recordB.computeDerivedMetrics()

        let fmAdvisor = AppleFoundationModelAdvisor()
        await fmAdvisor.enhance(record: &recordB, recognition: recognition)
        XCTAssertFalse(recordB.extractionDiagnosis.isEmpty)
        XCTAssertFalse(recordB.xiaohongshuCopy.isEmpty)
        XCTAssertFalse(recordB.wechatCopy.isEmpty)

        let caps = OnDeviceAICapabilities.currentCapabilities()
        XCTAssertTrue(caps.visionOCRAvailable)
        XCTAssertFalse(caps.activeAdvisorName.isEmpty)
        XCTAssertFalse(caps.summaryText.isEmpty)
    }

    func testNonCoffeeContentIsRejectedAndNeverSaved() async {
        let beforeRecords = recordStore.listRecords().count
        let beforeLibrary = beanStore.loadLibrary()

        let stub = StubMediaRecognizer(
            stubbedAudioTranscript: "今天天气真不错，中午去吃了个火锅，晚上打算看场电影。",
            stubbedVisualFields: VisualFieldReadings(),
            stubbedKeyframes: []
        )
        let pipeline = CoffeeIngestionPipeline(
            recordStore: recordStore,
            beanStore: beanStore,
            recognizer: stub,
            advisor: RuleBasedOfflineAdvisor()
        )

        let result = await pipeline.ingestMedia(
            mediaURL: tempDir.appendingPathComponent("random_chat.m4a"),
            spokenTranscript: "",
            sourceDevice: "iPhone 15 Pro",
            sourceType: .iphone,
            recordIntent: .auto,
            save: true
        )

        XCTAssertFalse(result.saved, "Non-coffee content must not be persisted")
        XCTAssertTrue(result.rejectedAsNonCoffee)
        XCTAssertNotNil(result.rejectionReason)
        XCTAssertNil(result.updatedEquipment)
        XCTAssertNil(result.deductedBean)
        XCTAssertEqual(recordStore.listRecords().count, beforeRecords)
        XCTAssertEqual(beanStore.loadLibrary(), beforeLibrary)

        // Also test direct text-only non-coffee reminder
        let textOnly = await pipeline.ingestMedia(
            mediaURL: nil,
            spokenTranscript: "记得明天早上九点开会，把PPT发给老板。",
            sourceDevice: "iPhone 15 Pro",
            sourceType: .iphone,
            recordIntent: .auto,
            save: true
        )
        XCTAssertFalse(textOnly.saved)
        XCTAssertTrue(textOnly.rejectedAsNonCoffee)
        XCTAssertEqual(recordStore.listRecords().count, beforeRecords)
    }

    func testEvidenceDrivenFrameClassificationNeverHallucinatesStages() {
        // 1. Silent frame with no OCR text -> honestly labeled as "scene_highlight" ("制作特写")
        let silent = AppleOnDeviceMediaRecognizer.classifyFrameByEvidence(
            timestampS: 22.0,
            durationS: 60.0,
            ocrTexts: [],
            speechSegments: []
        )
        XCTAssertEqual(silent.stageKey, "scene_highlight")
        XCTAssertEqual(silent.stageLabel, "制作特写")

        // 2. Scale reading anywhere in first 70% -> accurately detects bean weight & labels as scale_dose / dose_weigh
        let scale1 = AppleOnDeviceMediaRecognizer.classifyFrameByEvidence(
            timestampS: 21.0,
            durationS: 60.0,
            ocrTexts: ["00:00  18.2"],
            speechSegments: [],
            alreadyHasScaleDose: false
        )
        XCTAssertEqual(scale1.stageKey, "scale_dose")
        XCTAssertEqual(scale1.readings.beanWeightG, 18.2)

        let scale2 = AppleOnDeviceMediaRecognizer.classifyFrameByEvidence(
            timestampS: 32.0,
            durationS: 60.0,
            ocrTexts: ["18.1g"],
            speechSegments: [],
            alreadyHasScaleDose: true
        )
        XCTAssertEqual(scale2.stageKey, "dose_weigh")
        XCTAssertEqual(scale2.readings.beanWeightG, 18.1)

        // 3. Explicit speech mention of tamping (no WDT mentioned) -> labels as tamping
        let tamped = AppleOnDeviceMediaRecognizer.classifyFrameByEvidence(
            timestampS: 40.0,
            durationS: 60.0,
            ocrTexts: [],
            speechSegments: [SpeechSegment(text: "直接用压粉锤压实", timestampS: 39.5, durationS: 1.5)]
        )
        XCTAssertEqual(tamped.stageKey, "tamping")
        XCTAssertEqual(tamped.stageLabel, "压粉锤压粉")
    }
}
