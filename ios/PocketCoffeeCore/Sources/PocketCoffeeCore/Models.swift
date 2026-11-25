import Foundation

public enum RecordType: String, Codable, Sendable, CaseIterable {
    case brewReport = "brew_report"
    case equipmentProfile = "equipment_profile"
}

public enum RecordIntent: String, Codable, Sendable, CaseIterable {
    case auto = "auto"
    case brewReport = "brew_report"
    case equipmentProfile = "equipment_profile"
}

public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case video = "video"
    case audio = "audio"
    case text = "text"
}

public enum SourceType: String, Codable, Sendable, CaseIterable {
    case iphone = "iphone"
    case ipad = "ipad"
    case mac = "mac"
    case djiPocket = "dji_pocket"
    case audioNote = "audio_note"
    case manualText = "manual_text"
    case webUpload = "web_upload"

    public var displayName: String {
        switch self {
        case .iphone: return "iPhone 手机录制"
        case .ipad: return "iPad 平板录制"
        case .mac: return "Mac 桌面录制"
        case .djiPocket: return "DJI Osmo Pocket"
        case .audioNote: return "语音备忘录"
        case .manualText: return "手动文字/语音输入"
        case .webUpload: return "网页端导入"
        }
    }
}

public struct FlavorProfile: Codable, Equatable, Sendable {
    public var acidity: Double
    public var sweetness: Double
    public var body: Double
    public var aroma: Double
    public var aftertaste: Double
    public var balance: Double

    public init(
        acidity: Double = 6.5,
        sweetness: Double = 7.5,
        body: Double = 7.8,
        aroma: Double = 8.2,
        aftertaste: Double = 7.5,
        balance: Double = 7.6
    ) {
        self.acidity = acidity
        self.sweetness = sweetness
        self.body = body
        self.aroma = aroma
        self.aftertaste = aftertaste
        self.balance = balance
    }
}

public struct MissingField: Codable, Equatable, Sendable, Identifiable {
    public var id: String { field }
    public var field: String
    public var label: String

    public init(field: String, label: String) {
        self.field = field
        self.label = label
    }
}

public struct EquipmentItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var category: String
    public var spec: String
    public var role: String

    public init(id: String, name: String, category: String, spec: String = "", role: String = "") {
        self.id = id
        self.name = name
        self.category = category
        self.spec = spec
        self.role = role
    }
}

public struct TimelineEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(timestamp)-\(stage)" }
    public var timestamp: String
    public var stage: String
    public var detail: String

    public init(timestamp: String, stage: String, detail: String) {
        self.timestamp = timestamp
        self.stage = stage
        self.detail = detail
    }
}

public struct SpeechSegment: Codable, Equatable, Sendable {
    public var text: String
    public var timestampS: Double
    public var durationS: Double

    enum CodingKeys: String, CodingKey {
        case text
        case timestampS = "timestamp_s"
        case durationS = "duration_s"
    }

    public init(text: String, timestampS: Double, durationS: Double = 0.3) {
        self.text = text
        self.timestampS = timestampS
        self.durationS = durationS
    }
}

public struct KeyframeObservation: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(stageKey)-\(percentage)" }
    public var stageKey: String
    public var stage: String
    public var presetBadge: String?
    public var percentage: Int
    public var timestampS: Double
    public var detectedFields: [String: String]
    public var visualDescription: String
    public var ocrTexts: [String]
    public var sharpnessScore: Double
    public var imagePath: String?
    public var extracted: Bool

    enum CodingKeys: String, CodingKey {
        case stageKey = "stage_key"
        case stage
        case presetBadge = "preset_badge"
        case percentage
        case timestampS = "timestamp_s"
        case detectedFields = "detected_fields"
        case visualDescription = "visual_description"
        case ocrTexts = "ocr_texts"
        case sharpnessScore = "sharpness_score"
        case imagePath = "image_path"
        case extracted
    }

    public init(
        stageKey: String,
        stage: String,
        presetBadge: String? = nil,
        percentage: Int = 0,
        timestampS: Double = 0,
        detectedFields: [String: String] = [:],
        visualDescription: String = "",
        ocrTexts: [String] = [],
        sharpnessScore: Double = 0,
        imagePath: String? = nil,
        extracted: Bool = false
    ) {
        self.stageKey = stageKey
        self.stage = stage
        self.presetBadge = presetBadge
        self.percentage = percentage
        self.timestampS = timestampS
        self.detectedFields = detectedFields
        self.visualDescription = visualDescription
        self.ocrTexts = ocrTexts
        self.sharpnessScore = sharpnessScore
        self.imagePath = imagePath
        self.extracted = extracted
    }
}

public struct VisualFieldReadings: Codable, Equatable, Sendable {
    public var beanName: String?
    public var beanWeightG: Double?
    public var grindSetting: String?
    public var grinderModel: String?
    public var pressureBar: Double?
    public var waterTempC: Double?
    public var yieldG: Double?
    public var extractionTimeS: Double?

    enum CodingKeys: String, CodingKey {
        case beanName = "bean_name"
        case beanWeightG = "bean_weight_g"
        case grindSetting = "grind_setting"
        case grinderModel = "grinder_model"
        case pressureBar = "pressure_bar"
        case waterTempC = "water_temp_c"
        case yieldG = "yield_g"
        case extractionTimeS = "extraction_time_s"
    }

    public init(
        beanName: String? = nil,
        beanWeightG: Double? = nil,
        grindSetting: String? = nil,
        grinderModel: String? = nil,
        pressureBar: Double? = nil,
        waterTempC: Double? = nil,
        yieldG: Double? = nil,
        extractionTimeS: Double? = nil
    ) {
        self.beanName = beanName
        self.beanWeightG = beanWeightG
        self.grindSetting = grindSetting
        self.grinderModel = grinderModel
        self.pressureBar = pressureBar
        self.waterTempC = waterTempC
        self.yieldG = yieldG
        self.extractionTimeS = extractionTimeS
    }

    public func merged(overridingWith other: VisualFieldReadings) -> VisualFieldReadings {
        VisualFieldReadings(
            beanName: other.beanName ?? beanName,
            beanWeightG: other.beanWeightG ?? beanWeightG,
            grindSetting: other.grindSetting ?? grindSetting,
            grinderModel: other.grinderModel ?? grinderModel,
            pressureBar: other.pressureBar ?? pressureBar,
            waterTempC: other.waterTempC ?? waterTempC,
            yieldG: other.yieldG ?? yieldG,
            extractionTimeS: other.extractionTimeS ?? extractionTimeS
        )
    }

    public var asDisplayDictionary: [String: String] {
        var out: [String: String] = [:]
        if let v = beanName { out["bean_name"] = v }
        if let v = beanWeightG { out["bean_weight_g"] = String(format: "%.1fg", v) }
        if let v = grindSetting { out["grind_setting"] = v }
        if let v = grinderModel { out["grinder_model"] = v }
        if let v = pressureBar { out["pressure_bar"] = String(format: "%.1f bar", v) }
        if let v = waterTempC { out["water_temp_c"] = String(format: "%.1f°C", v) }
        if let v = yieldG { out["yield_g"] = String(format: "%.1fg", v) }
        if let v = extractionTimeS { out["extraction_time_s"] = String(format: "%.1fs", v) }
        return out
    }
}

public struct RecognitionOutput: Codable, Equatable, Sendable {
    public var mediaKind: MediaKind
    public var mediaPath: String?
    public var sourceDevice: String
    public var audioTranscript: String
    public var transcript: String
    public var speechSegments: [SpeechSegment]
    public var visualFields: VisualFieldReadings
    public var keyframes: [KeyframeObservation]
    public var durationS: Double?
    public var visualSceneTags: [String]

    enum CodingKeys: String, CodingKey {
        case mediaKind, mediaPath, sourceDevice, audioTranscript, transcript
        case speechSegments, visualFields, keyframes, durationS, visualSceneTags
    }

    public init(
        mediaKind: MediaKind,
        mediaPath: String? = nil,
        sourceDevice: String = "iPhone 手机录制",
        audioTranscript: String = "",
        transcript: String = "",
        speechSegments: [SpeechSegment] = [],
        visualFields: VisualFieldReadings = VisualFieldReadings(),
        keyframes: [KeyframeObservation] = [],
        durationS: Double? = nil,
        visualSceneTags: [String] = []
    ) {
        self.mediaKind = mediaKind
        self.mediaPath = mediaPath
        self.sourceDevice = sourceDevice
        self.audioTranscript = audioTranscript
        self.transcript = transcript
        self.speechSegments = speechSegments
        self.visualFields = visualFields
        self.keyframes = keyframes
        self.durationS = durationS
        self.visualSceneTags = visualSceneTags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mediaKind = try c.decode(MediaKind.self, forKey: .mediaKind)
        self.mediaPath = try c.decodeIfPresent(String.self, forKey: .mediaPath)
        self.sourceDevice = try c.decodeIfPresent(String.self, forKey: .sourceDevice) ?? "iPhone 手机录制"
        self.audioTranscript = try c.decodeIfPresent(String.self, forKey: .audioTranscript) ?? ""
        self.transcript = try c.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        self.speechSegments = try c.decodeIfPresent([SpeechSegment].self, forKey: .speechSegments) ?? []
        self.visualFields = try c.decodeIfPresent(VisualFieldReadings.self, forKey: .visualFields) ?? VisualFieldReadings()
        self.keyframes = try c.decodeIfPresent([KeyframeObservation].self, forKey: .keyframes) ?? []
        self.durationS = try c.decodeIfPresent(Double.self, forKey: .durationS)
        self.visualSceneTags = try c.decodeIfPresent([String].self, forKey: .visualSceneTags) ?? []
    }
}

public struct CoffeeRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var createdAt: String
    public var cameraDevice: String
    public var sourceType: SourceType
    public var mediaKind: MediaKind
    public var videoPath: String?
    public var mediaURL: String?
    public var transcript: String

    // Core brew parameters
    public var beanName: String?
    public var beanRoast: String?
    public var beanWeightG: Double?
    public var grindSetting: String?
    public var grinderType: String?
    public var grinderModel: String?
    public var brewMethod: String?
    public var yieldG: Double?
    public var extractionTimeS: Double?
    public var pressureBar: Double?
    public var waterTempC: Double?
    public var brewRatio: String?

    // AI / Barista analysis
    public var extractionDiagnosis: String
    public var suggestions: [String]
    public var xiaohongshuCopy: String
    public var wechatCopy: String
    public var flavorNotes: [String]
    public var flavorProfile: FlavorProfile
    public var timelineEvents: [TimelineEvent]
    public var keyframes: [KeyframeObservation]

    // Classification & equipment
    public var recordType: RecordType
    public var equipmentItems: [EquipmentItem]

    // Status
    public var missingFields: [MissingField]
    public var status: String // "complete" | "needs_info"

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case cameraDevice = "camera_device"
        case sourceType = "source_type"
        case mediaKind = "media_kind"
        case videoPath = "video_path"
        case mediaURL = "media_url"
        case transcript
        case beanName = "bean_name"
        case beanRoast = "bean_roast"
        case beanWeightG = "bean_weight_g"
        case grindSetting = "grind_setting"
        case grinderType = "grinder_type"
        case grinderModel = "grinder_model"
        case brewMethod = "brew_method"
        case yieldG = "yield_g"
        case extractionTimeS = "extraction_time_s"
        case pressureBar = "pressure_bar"
        case waterTempC = "water_temp_c"
        case brewRatio = "brew_ratio"
        case extractionDiagnosis = "extraction_diagnosis"
        case suggestions
        case xiaohongshuCopy = "xiaohongshu_copy"
        case wechatCopy = "wechat_copy"
        case flavorNotes = "flavor_notes"
        case flavorProfile = "flavor_profile"
        case timelineEvents = "timeline_events"
        case keyframes
        case recordType = "record_type"
        case equipmentItems = "equipment_items"
        case missingFields = "missing_fields"
        case status
    }

    public static let requiredBrewFields: [(key: String, label: String)] = [
        ("bean_name", "咖啡豆名称/产地"),
        ("bean_weight_g", "咖啡豆称重 (g)"),
        ("grind_setting", "研磨度刻度"),
        ("grinder_type", "研磨机器 (独立磨豆机/自带磨豆机)"),
        ("grinder_model", "磨豆机具体型号"),
        ("brew_method", "制作方式 (意式浓缩 / 冷萃 / 美式 / 拿铁)"),
        ("yield_g", "萃取液重/出液量 (g/ml)"),
        ("extraction_time_s", "萃取时间 (s)"),
        ("pressure_bar", "萃取压力 (bar)"),
    ]

    public init(
        id: String = CoffeeRecord.makeID(),
        createdAt: String = CoffeeRecord.nowString(),
        cameraDevice: String = "iPhone 手机录制",
        sourceType: SourceType = .iphone,
        mediaKind: MediaKind = .video,
        videoPath: String? = nil,
        mediaURL: String? = nil,
        transcript: String = "",
        beanName: String? = nil,
        beanRoast: String? = nil,
        beanWeightG: Double? = nil,
        grindSetting: String? = nil,
        grinderType: String? = nil,
        grinderModel: String? = nil,
        brewMethod: String? = nil,
        yieldG: Double? = nil,
        extractionTimeS: Double? = nil,
        pressureBar: Double? = nil,
        waterTempC: Double? = nil,
        brewRatio: String? = nil,
        extractionDiagnosis: String = "",
        suggestions: [String] = [],
        xiaohongshuCopy: String = "",
        wechatCopy: String = "",
        flavorNotes: [String] = [],
        flavorProfile: FlavorProfile = FlavorProfile(),
        timelineEvents: [TimelineEvent] = [],
        keyframes: [KeyframeObservation] = [],
        recordType: RecordType = .brewReport,
        equipmentItems: [EquipmentItem] = [],
        missingFields: [MissingField] = [],
        status: String = "complete"
    ) {
        self.id = id
        self.createdAt = createdAt
        self.cameraDevice = cameraDevice
        self.sourceType = sourceType
        self.mediaKind = mediaKind
        self.videoPath = videoPath
        self.mediaURL = mediaURL
        self.transcript = transcript
        self.beanName = beanName
        self.beanRoast = beanRoast
        self.beanWeightG = beanWeightG
        self.grindSetting = grindSetting
        self.grinderType = grinderType
        self.grinderModel = grinderModel
        self.brewMethod = brewMethod
        self.yieldG = yieldG
        self.extractionTimeS = extractionTimeS
        self.pressureBar = pressureBar
        self.waterTempC = waterTempC
        self.brewRatio = brewRatio
        self.extractionDiagnosis = extractionDiagnosis
        self.suggestions = suggestions
        self.xiaohongshuCopy = xiaohongshuCopy
        self.wechatCopy = wechatCopy
        self.flavorNotes = flavorNotes
        self.flavorProfile = flavorProfile
        self.timelineEvents = timelineEvents
        self.keyframes = keyframes
        self.recordType = recordType
        self.equipmentItems = equipmentItems
        self.missingFields = missingFields
        self.status = status
    }

    public mutating func computeDerivedMetrics() {
        if recordType == .equipmentProfile {
            missingFields = []
            status = "complete"
            return
        }
        if let w = beanWeightG, let y = yieldG, w > 0 {
            let ratio = (y / w * 100).rounded() / 100
            brewRatio = String(format: "1:%.2f", ratio)
        }
        var missing: [MissingField] = []
        if isEmpty(beanName) { missing.append(MissingField(field: "bean_name", label: "咖啡豆名称/产地")) }
        if beanWeightG == nil { missing.append(MissingField(field: "bean_weight_g", label: "咖啡豆称重 (g)")) }
        if isEmpty(grindSetting) { missing.append(MissingField(field: "grind_setting", label: "研磨度刻度")) }
        if isEmpty(grinderType) { missing.append(MissingField(field: "grinder_type", label: "研磨机器 (独立磨豆机/自带磨豆机)")) }
        if isEmpty(grinderModel) { missing.append(MissingField(field: "grinder_model", label: "磨豆机具体型号")) }
        if isEmpty(brewMethod) { missing.append(MissingField(field: "brew_method", label: "制作方式 (意式浓缩 / 冷萃 / 美式 / 拿铁)")) }
        if yieldG == nil { missing.append(MissingField(field: "yield_g", label: "萃取液重/出液量 (g/ml)")) }
        if extractionTimeS == nil { missing.append(MissingField(field: "extraction_time_s", label: "萃取时间 (s)")) }
        if pressureBar == nil {
            if let method = brewMethod,
               ["冷萃", "手冲", "法压", "滤挂", "挂耳"].contains(where: { method.contains($0) }) {
                pressureBar = 1.0
            } else {
                missing.append(MissingField(field: "pressure_bar", label: "萃取压力 (bar)"))
            }
        }
        missingFields = missing
        status = missing.isEmpty ? "complete" : "needs_info"
    }

    private func isEmpty(_ str: String?) -> Bool {
        guard let str else { return true }
        return str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func makeID() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        return "brew-\(fmt.string(from: Date()))-\(suffix)"
    }

    public static func nowString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: Date())
    }
}

public struct BeanFreshnessInfo: Equatable, Sendable {
    public enum Level: String, Sendable {
        case resting      // 养豆期 (0-6 天)
        case peak         // 最佳风味期 (7-45 天)
        case steady       // 风味平稳期 (46-90 天)
        case fading       // 风味衰减 / 临近到期
        case expired      // 已过赏味期/到期
    }

    public let level: Level
    public let badgeText: String
    public let detailText: String
    public let daysSinceRoast: Int?
    public let daysUntilExpiry: Int?
}

public struct BeanEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var shortAliases: [String]
    public var fullName: String
    public var roastLevel: String
    public var roastDate: String
    public var expiryDate: String
    public var initialWeightG: Double
    public var remainingWeightG: Double
    public var recommendedGrind: String
    public var flavorTags: [String]
    public var goldenRecipeNote: String
    public var shotsCount: Int
    public var coverImagePath: String?
    public var photoPaths: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case shortAliases = "short_aliases"
        case fullName = "full_name"
        case roastLevel = "roast_level"
        case roastDate = "roast_date"
        case expiryDate = "expiry_date"
        case initialWeightG = "initial_weight_g"
        case remainingWeightG = "remaining_weight_g"
        case recommendedGrind = "recommended_grind"
        case flavorTags = "flavor_tags"
        case goldenRecipeNote = "golden_recipe_note"
        case shotsCount = "shots_count"
        case coverImagePath = "cover_image_path"
        case photoPaths = "photo_paths"
    }

    public var allPhotoPaths: [String] {
        var result: [String] = []
        if let cover = coverImagePath, !cover.isEmpty {
            result.append(cover)
        }
        for path in photoPaths where !path.isEmpty && !result.contains(path) {
            result.append(path)
        }
        return result
    }

    public init(
        id: String = "bean-\(UUID().uuidString.prefix(6).lowercased())",
        shortAliases: [String] = [],
        fullName: String,
        roastLevel: String = "中浅烘焙",
        roastDate: String = "",
        expiryDate: String = "",
        initialWeightG: Double = 250,
        remainingWeightG: Double? = nil,
        recommendedGrind: String = "",
        flavorTags: [String] = [],
        goldenRecipeNote: String = "",
        shotsCount: Int = 0,
        coverImagePath: String? = nil,
        photoPaths: [String] = []
    ) {
        self.id = id
        self.shortAliases = shortAliases
        self.fullName = fullName
        self.roastLevel = roastLevel
        self.roastDate = roastDate
        self.expiryDate = expiryDate
        self.initialWeightG = initialWeightG
        self.remainingWeightG = remainingWeightG ?? initialWeightG
        self.recommendedGrind = recommendedGrind
        self.flavorTags = flavorTags
        self.goldenRecipeNote = goldenRecipeNote
        self.shotsCount = shotsCount
        self.coverImagePath = coverImagePath ?? photoPaths.first
        self.photoPaths = photoPaths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? "bean-\(UUID().uuidString.prefix(6).lowercased())"
        self.shortAliases = try c.decodeIfPresent([String].self, forKey: .shortAliases) ?? []
        self.fullName = try c.decodeIfPresent(String.self, forKey: .fullName) ?? "未命名咖啡豆"
        self.roastLevel = try c.decodeIfPresent(String.self, forKey: .roastLevel) ?? "中浅烘焙"
        self.roastDate = try c.decodeIfPresent(String.self, forKey: .roastDate) ?? ""
        self.expiryDate = try c.decodeIfPresent(String.self, forKey: .expiryDate) ?? ""
        let initW = try c.decodeIfPresent(Double.self, forKey: .initialWeightG) ?? 250
        self.initialWeightG = initW
        self.remainingWeightG = try c.decodeIfPresent(Double.self, forKey: .remainingWeightG) ?? initW
        self.recommendedGrind = try c.decodeIfPresent(String.self, forKey: .recommendedGrind) ?? ""
        self.flavorTags = try c.decodeIfPresent([String].self, forKey: .flavorTags) ?? []
        self.goldenRecipeNote = try c.decodeIfPresent(String.self, forKey: .goldenRecipeNote) ?? ""
        self.shotsCount = try c.decodeIfPresent(Int.self, forKey: .shotsCount) ?? 0
        let decodedPhotos = try c.decodeIfPresent([String].self, forKey: .photoPaths) ?? []
        self.coverImagePath = try c.decodeIfPresent(String.self, forKey: .coverImagePath) ?? decodedPhotos.first
        self.photoPaths = decodedPhotos
    }

    /// Evaluates coffee freshness & flavor window based on `roastDate` (production/roast date)
    /// and optional `expiryDate` (best-before/expiry date).
    public func freshnessInfo(referenceDate: Date = Date()) -> BeanFreshnessInfo? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: referenceDate)

        let roastParsed = Self.parseISODate(roastDate)
        let expiryParsed = Self.parseISODate(expiryDate)

        let daysSinceRoast = roastParsed.flatMap { cal.dateComponents([.day], from: cal.startOfDay(for: $0), to: today).day }
        let daysUntilExpiry = expiryParsed.flatMap { cal.dateComponents([.day], from: today, to: cal.startOfDay(for: $0)).day }

        if daysSinceRoast == nil && daysUntilExpiry == nil {
            return nil
        }

        // Expiry takes precedence when expired or within 14 days
        if let until = daysUntilExpiry {
            if until < 0 {
                let over = abs(until)
                let roastNote = daysSinceRoast.map { "烘焙后 \($0) 天 · " } ?? ""
                return BeanFreshnessInfo(
                    level: .expired,
                    badgeText: "已过赏味期 \(over) 天",
                    detailText: "\(roastNote)风味香气衰减较明显，建议偏细研磨或做冰奶咖/冷萃",
                    daysSinceRoast: daysSinceRoast,
                    daysUntilExpiry: until
                )
            }
            if until <= 14 {
                let roastNote = daysSinceRoast.map { "烘焙后 \($0) 天 · " } ?? ""
                return BeanFreshnessInfo(
                    level: .fading,
                    badgeText: until == 0 ? "今日到期" : "距到期仅 \(until) 天",
                    detailText: "\(roastNote)临近赏味期末尾，建议尽快享用",
                    daysSinceRoast: daysSinceRoast,
                    daysUntilExpiry: until
                )
            }
        }

        let expirySuffix = daysUntilExpiry.map { " · 距到期 \($0) 天" } ?? ""

        if let since = daysSinceRoast {
            if since < 0 {
                return BeanFreshnessInfo(
                    level: .resting,
                    badgeText: "待养豆",
                    detailText: "生产日期为 \(roastDate)\(expirySuffix)",
                    daysSinceRoast: since,
                    daysUntilExpiry: daysUntilExpiry
                )
            } else if since <= 6 {
                return BeanFreshnessInfo(
                    level: .resting,
                    badgeText: "养豆期 · 第 \(max(1, since)) 天",
                    detailText: "二氧化碳排气中，意式建议养豆 7-10 天后风味更甜润\(expirySuffix)",
                    daysSinceRoast: since,
                    daysUntilExpiry: daysUntilExpiry
                )
            } else if since <= 45 {
                return BeanFreshnessInfo(
                    level: .peak,
                    badgeText: "最佳风味期 · 第 \(since) 天",
                    detailText: "香气饱满、油脂丰富，处于黄金赏味窗口\(expirySuffix)",
                    daysSinceRoast: since,
                    daysUntilExpiry: daysUntilExpiry
                )
            } else if since <= 90 {
                return BeanFreshnessInfo(
                    level: .steady,
                    badgeText: "风味平稳期 · 第 \(since) 天",
                    detailText: "花果调略有柔和，可微调偏细 0.5 格补偿流速\(expirySuffix)",
                    daysSinceRoast: since,
                    daysUntilExpiry: daysUntilExpiry
                )
            } else {
                return BeanFreshnessInfo(
                    level: .fading,
                    badgeText: "风味衰减期 · 第 \(since) 天",
                    detailText: "烘焙已超 3 个月，建议调细研磨或搭配牛奶/冷萃\(expirySuffix)",
                    daysSinceRoast: since,
                    daysUntilExpiry: daysUntilExpiry
                )
            }
        }

        if let until = daysUntilExpiry {
            return BeanFreshnessInfo(
                level: .peak,
                badgeText: "距到期 \(until) 天",
                detailText: "处于赏味期内，建议密封避光保存",
                daysSinceRoast: nil,
                daysUntilExpiry: until
            )
        }
        return nil
    }

    public static func parseISODate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: String(trimmed.prefix(10)))
    }
}

public struct EquipmentProfile: Codable, Equatable, Sendable {
    public var espressoMachine: String
    public var defaultGrinderType: String
    public var defaultGrinderModel: String
    public var secondaryGrinderModel: String
    public var defaultWaterTempC: Double
    public var autoFillDefaultGrinder: Bool
    public var accessories: [EquipmentItem]
    public var machinePhotoPath: String?

    enum CodingKeys: String, CodingKey {
        case espressoMachine = "espresso_machine"
        case defaultGrinderType = "default_grinder_type"
        case defaultGrinderModel = "default_grinder_model"
        case secondaryGrinderModel = "secondary_grinder_model"
        case defaultWaterTempC = "default_water_temp_c"
        case autoFillDefaultGrinder = "auto_fill_default_grinder"
        case accessories
        case machinePhotoPath = "machine_photo_path"
    }

    public init(
        espressoMachine: String = "格米莱 G3828A (云象One)",
        defaultGrinderType: String = "额外独立磨豆机",
        defaultGrinderModel: String = "Niche Zero (63mm 锥刀)",
        secondaryGrinderModel: String = "咖啡机内置磨豆机",
        defaultWaterTempC: Double = 93.0,
        autoFillDefaultGrinder: Bool = true,
        accessories: [EquipmentItem] = [],
        machinePhotoPath: String? = nil
    ) {
        self.espressoMachine = espressoMachine
        self.defaultGrinderType = defaultGrinderType
        self.defaultGrinderModel = defaultGrinderModel
        self.secondaryGrinderModel = secondaryGrinderModel
        self.defaultWaterTempC = defaultWaterTempC
        self.autoFillDefaultGrinder = autoFillDefaultGrinder
        self.accessories = accessories
        self.machinePhotoPath = machinePhotoPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.espressoMachine = try c.decodeIfPresent(String.self, forKey: .espressoMachine) ?? "格米莱 G3828A (云象One)"
        self.defaultGrinderType = try c.decodeIfPresent(String.self, forKey: .defaultGrinderType) ?? "额外独立磨豆机"
        self.defaultGrinderModel = try c.decodeIfPresent(String.self, forKey: .defaultGrinderModel) ?? "Niche Zero (63mm 锥刀)"
        self.secondaryGrinderModel = try c.decodeIfPresent(String.self, forKey: .secondaryGrinderModel) ?? "咖啡机内置磨豆机"
        self.defaultWaterTempC = try c.decodeIfPresent(Double.self, forKey: .defaultWaterTempC) ?? 93.0
        self.autoFillDefaultGrinder = try c.decodeIfPresent(Bool.self, forKey: .autoFillDefaultGrinder) ?? true
        self.accessories = try c.decodeIfPresent([EquipmentItem].self, forKey: .accessories) ?? []
        self.machinePhotoPath = try c.decodeIfPresent(String.self, forKey: .machinePhotoPath)
    }
}

public struct BeanEquipmentLibrary: Codable, Equatable, Sendable {
    public var beans: [BeanEntry]
    public var equipment: EquipmentProfile
    /// Normalized names/aliases of beans explicitly deleted by the user so startup
    /// record backfill never resurrects a deleted bean card across app restarts.
    public var dismissedBeanNames: [String]

    enum CodingKeys: String, CodingKey {
        case beans
        case equipment
        case dismissedBeanNames = "dismissed_bean_names"
    }

    public init(
        beans: [BeanEntry] = [],
        equipment: EquipmentProfile = EquipmentProfile(),
        dismissedBeanNames: [String] = []
    ) {
        self.beans = beans
        self.equipment = equipment
        self.dismissedBeanNames = dismissedBeanNames
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.beans = try c.decodeIfPresent([BeanEntry].self, forKey: .beans) ?? []
        self.equipment = try c.decodeIfPresent(EquipmentProfile.self, forKey: .equipment) ?? EquipmentProfile()
        self.dismissedBeanNames = try c.decodeIfPresent([String].self, forKey: .dismissedBeanNames) ?? []
    }
}

public struct PipelineResult: Equatable, Sendable {
    public var record: CoffeeRecord
    public var recognition: RecognitionOutput
    public var saved: Bool
    public var updatedEquipment: EquipmentProfile?
    public var deductedBean: BeanEntry?
    public var advisorBackend: String
    public var rejectedAsNonCoffee: Bool
    public var rejectionReason: String?

    public init(
        record: CoffeeRecord,
        recognition: RecognitionOutput,
        saved: Bool,
        updatedEquipment: EquipmentProfile? = nil,
        deductedBean: BeanEntry? = nil,
        advisorBackend: String = "rule_based_offline",
        rejectedAsNonCoffee: Bool = false,
        rejectionReason: String? = nil
    ) {
        self.record = record
        self.recognition = recognition
        self.saved = saved
        self.updatedEquipment = updatedEquipment
        self.deductedBean = deductedBean
        self.advisorBackend = advisorBackend
        self.rejectedAsNonCoffee = rejectedAsNonCoffee
        self.rejectionReason = rejectionReason
    }
}
