import Foundation

/// Swift port of `core/analyzer.py`: multimodal (voice + video) coffee brewing analyzer
/// and barista AI engine. Extracts structured coffee parameters from spoken Chinese
/// transcripts (including ASR homophones such as 「初夜」→ 出液 and 「酒八」→ 9bar),
/// classifies equipment-introduction recordings, evaluates extraction quality, and
/// generates Xiaohongshu / WeChat social copy. All behavior mirrors the Python backend.
public enum ChineseCoffeeAnalyzer {

    // MARK: - Chinese numeral parsing

    private static let maxTranscriptLength = 20_000

    private static let cnNums: [Character: Int] = [
        "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
    ]

    private static func safeInt(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        if value >= Double(Int.max - 1) { return Int.max - 1 }
        if value <= Double(Int.min + 1) { return Int.min + 1 }
        return Int(value)
    }

    /// Parses Arabic floats ("18.5") and spoken Chinese numerals
    /// ("十八" → 18, "二十八" → 28, "九点五" → 9.5, "两" → 2).
    public static func parseChineseOrDouble(_ raw: String) -> Double? {
        let valStr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !valStr.isEmpty, valStr.count <= 64 else { return nil }
        if let value = Double(valStr) {
            return (value.isFinite && abs(value) <= 1_000_000) ? value : nil
        }

        if valStr.contains("点") {
            let parts = valStr.split(separator: "点", maxSplits: 1, omittingEmptySubsequences: false)
            guard let leftVal = parseChineseOrDouble(String(parts[0])),
                  leftVal.isFinite,
                  leftVal >= 0,
                  leftVal <= 1_000_000
            else {
                return nil
            }
            let rightSource = parts.count > 1 ? String(parts[1]) : ""
            let rightDigits = rightSource.map { char -> String in
                if let digit = cnNums[char] { return String(digit) }
                return String(char)
            }.joined()
            let whole = safeInt(leftVal)
            if rightDigits.isEmpty { return Double(whole) }
            guard rightDigits.allSatisfy(\.isNumber),
                  let combined = Double("\(whole).\(rightDigits)"),
                  combined.isFinite,
                  abs(combined) <= 1_000_000
            else {
                return nil
            }
            return combined
        }

        let chars = Array(valStr)
        if chars.first == "十" {
            var total = 10
            if chars.count > 1 { total += cnNums[chars[1]] ?? 0 }
            return Double(total)
        }
        if valStr.contains("十") {
            let parts = valStr.split(separator: "十", omittingEmptySubsequences: false)
            var tens = 10
            if let first = parts.first, first.count == 1, let ch = first.first, let n = cnNums[ch] {
                tens = n * 10
            }
            var ones = 0
            if parts.count > 1, parts[1].count == 1, let ch = parts[1].first {
                ones = cnNums[ch] ?? 0
            }
            return Double(tens + ones)
        }
        if chars.count == 1, let ch = chars.first, let n = cnNums[ch] {
            return Double(n)
        }
        return nil
    }

    // MARK: - Regex helpers

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges > 1 else { return nil }
        let captureRange = match.range(at: 1)
        guard captureRange.location != NSNotFound else { return nil }
        return nsText.substring(with: captureRange)
    }

    private static func replacingMatches(of pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: nsText.length),
            withTemplate: template
        )
    }

    private static func isNilOrEmpty(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.isEmpty
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Python-style `str(float)` formatting (18.0 → "18.0", 9.2 → "9.2").
    private static func floatStr(_ value: Double) -> String { "\(value)" }

    /// Mirrors Python's `value or '--'` truthiness (nil and 0 both render as "--").
    private static func orDash(_ value: Double?) -> String {
        guard let value, value != 0 else { return "--" }
        return floatStr(value)
    }

    /// Python `round(value, digits)` semantics (round-half-to-even).
    private static func pyRound(_ value: Double, _ digits: Int) -> Double {
        let factor = pow(10.0, Double(digits))
        return (value * factor).rounded(.toNearestOrEven) / factor
    }

    // MARK: - Text normalization (Traditional Chinese + ASR homophones)

    private static let traditionalToSimplifiedMap: [(String, String)] = [
        ("義式", "意式"), ("濃縮", "浓缩"), ("手沖", "手冲"), ("沖煮", "冲煮"),
        ("濾杯", "滤杯"), ("濾紙", "滤纸"), ("濾掛", "滤挂"), ("掛耳", "挂耳"), ("職啡機", "咖啡机"),
        ("摩卡壺", "摩卡壶"), ("愛樂壓", "爱乐压"),
        ("法壓壺", "法压壶"), ("壓粉", "压粉"), ("接粉環", "接粉环"), ("集粉環", "接粉环"),
        ("咖啡機", "咖啡机"), ("磨豆機", "磨豆机"), ("電子秤", "电子秤"), ("清潔", "清洁"),
        ("膠囊", "胶囊"), ("拿鐵", "拿铁"), ("熱水", "热水"), ("悶蒸", "闷蒸"),
        ("時間", "时间"), ("溫度", "温度"), ("壓力", "压力"), ("機器", "机器"),
        ("鐵", "铁"), ("壺", "壶"), ("壓", "压"), ("濾", "滤"), ("沖", "冲"),
        ("機", "机"), ("環", "环"), ("濃", "浓"), ("縮", "缩"), ("潔", "洁"),
        ("壓粪锤", "压粉锤"), ("压粪锤", "压粉锤"), ("鸭粉锤", "压粉锤"),
        ("开始吹吹", "开始萃取"), ("处理一下结款", "处理一下结块"),
        // 6 major espresso machine brands: Traditional Chinese & ASR homophones
        ("白胜图", "百胜图"), ("百圣图", "百胜图"), ("百盛图", "百胜图"), ("百胜涂", "百胜图"), ("白圣图", "百胜图"),
        ("格米萊", "格米莱"), ("格莱米", "格米莱"), ("格米来", "格米莱"), ("可爱米", "格米莱"),
        ("佩洛奇", "佩罗奇"), ("配罗奇", "佩罗奇"), ("佩洛齐", "佩罗奇"), ("佩罗齐", "佩罗奇"), ("赔罗奇", "佩罗奇"),
        ("马克西母", "马克西姆"), ("马克西木", "马克西姆"),
        ("德龍", "德龙"), ("得龙", "德龙"), ("德隆", "德龙"), ("得隆", "德龙"),
        // Steaming / milk-frothing / tutorial ASR homophones
        ("单孔音世界", "单孔意式机"), ("音世界", "意式机"),
        ("打奶炮", "打奶泡"), ("奶高", "奶缸"), ("打棉", "打绵"), ("牛腩页面", "牛奶液面"),
        ("阎魔", "研磨"), ("浴巾套", "预浸泡"), ("卒取", "萃取"),
    ]

    public static func normalizeCoffeeText(_ raw: String) -> String {
        var result = String(raw.prefix(maxTranscriptLength + 4_096))
        for (src, dst) in traditionalToSimplifiedMap {
            if result.contains(src) {
                result = result.replacingOccurrences(of: src, with: dst)
            }
        }
        return result
    }

    // MARK: - Non-coffee content relevance gatekeeper

    private static let coffeeRelevanceKeywords: [String] = [
        "咖啡", "浓缩", "意式", "美式", "拿铁", "冷萃", "冰滴", "手冲", "萃取", "预浸泡",
        "粉液比", "粉水比", "粉量", "粉重", "液重", "出液", "称豆", "磨豆", "研磨", "刻度", "压粉",
        "布粉", "手柄", "豆仓", "烘焙", "浅烘", "中烘", "深烘", "水洗", "日晒", "厌氧",
        "油脂", "虎斑", "耶加", "瑰夏", "花魁", "西达摩", "曼特宁", "soe", "espresso",
        "latte", "cappuccino", "americano", "flat white", "cortado", "cold brew", "pour over",
        "pourover", "v60", "chemex", "kalita", "moka", "bialetti", "aeropress", "french press",
        "barista", "crema", "grinder", "portafilter", "tamper", "tamping", "dosing", "coffee",
        "拉花", "奶泡", "打奶泡", "蒸汽棒", "奶缸", "意式机", "变压模式", "滤杯", "滤纸", "闷蒸", "澳白", "卡布奇诺", "粉杯", "接粉环",
        "格米莱", "gemilai", "crm3605", "crm3005", "crm3145", "g3007l", "3828",
        "百胜图", "barsetto", "2sap", "bae02s", "bae01", "bae02",
        "米家咖啡机", "小米咖啡机", "mijia",
        "佩罗奇", "peloqi",
        "马克西姆", "mokkom", "塞纳",
        "德龙", "de'longhi", "delonghi", "dedica", "ec685", "ec885", "ec9355", "ec9865",
        "铂富", "niche", "df64", "ek43", "breville", "acaia",
        "rancilio", "lelit", "la marzocco", "timemore", "hario", "kinu",
        "轰炸机", "摩卡壶", "法压壶", "爱乐压", "dirty",
    ]

    /// Returns `true` only when the transcript, OCR captions, visual field readings,
    /// visual scene tags (for silent/ASMR videos), or bean library match contain genuine
    /// coffee brewing or coffee-equipment signals. Prevents unrelated recordings
    /// (e.g. casual chat, meeting reminders) from polluting the coffee archive.
    public static func isCoffeeRelated(
        transcript: String,
        visualFields: VisualFieldReadings? = nil,
        matchedBean: BeanEntry? = nil,
        ocrTexts: [String] = [],
        visualSceneTags: [String] = []
    ) -> Bool {
        if matchedBean != nil { return true }
        if let vf = visualFields, !vf.asDisplayDictionary.isEmpty { return true }

        let trimmed = String(transcript.prefix(maxTranscriptLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        var boundedOCRChunks: [String] = []
        var totalOCRChars = 0
        for line in ocrTexts.prefix(160) where totalOCRChars < 8_000 {
            let chunk = String(line.prefix(400)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunk.isEmpty else { continue }
            boundedOCRChunks.append(chunk)
            totalOCRChars += chunk.count + 1
        }
        let ocrCombined = String(boundedOCRChunks.joined(separator: " ").prefix(8_000))
        let normalizedCombined = normalizeCoffeeText(
            trimmed.isEmpty ? ocrCombined : (ocrCombined.isEmpty ? trimmed : "\(trimmed)\n\(ocrCombined)")
        )

        if !normalizedCombined.isEmpty {
            let lowered = normalizedCombined.lowercased()
            if coffeeRelevanceKeywords.contains(where: { lowered.contains($0) }) {
                return true
            }

            // Check whether parameter extraction (without permanent equipment defaults) finds any brew metric
            let probe = extractParameters(
                transcript: normalizedCombined,
                visualOverrides: nil,
                matchedBean: nil,
                equipmentDefaults: nil
            )
            if probe.beanName != nil
                || probe.beanRoast != nil
                || probe.beanWeightG != nil
                || probe.grindSetting != nil
                || probe.grinderType != nil
                || probe.grinderModel != nil
                || probe.brewMethod != nil
                || probe.yieldG != nil
                || probe.extractionTimeS != nil
                || probe.pressureBar != nil
                || probe.waterTempC != nil {
                return true
            }
        }

        // Silent / ASMR / BGM video fallback:
        // 1) When there is no spoken transcript, accept if Vision confirms coffee or drinkware+barware.
        // 2) Even if background music caused noisy ASR hallucinations, accept when Vision sees BOTH
        //    a direct coffee class (`coffee`/`espresso`/`latte`/`coffee_maker`) AND a machine/appliance.
        if !visualSceneTags.isEmpty {
            let tagSet = Set(visualSceneTags.map { $0.lowercased() })
            let directCoffee: Set<String> = ["coffee", "espresso", "latte", "cappuccino", "coffee_maker", "espresso_maker"]
            let hardware: Set<String> = ["machine", "appliance", "coffee_maker", "espresso_maker"]
            if !tagSet.isDisjoint(with: directCoffee) && !tagSet.isDisjoint(with: hardware) {
                return true
            }
            if trimmed.isEmpty {
                if !tagSet.isDisjoint(with: directCoffee) {
                    return true
                }
                let drinkware: Set<String> = ["cup", "mug", "drinking_glass", "drink", "beverage", "kettle", "teapot"]
                let barContext: Set<String> = ["tableware", "utensil", "appliance", "machine"]
                if !tagSet.isDisjoint(with: drinkware) && !tagSet.isDisjoint(with: barContext) {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Parameter extraction

    /// Parses a spoken Chinese brew transcript (plus optional visual scale/gauge readings,
    /// bean-library shorthand match, and permanent equipment defaults) into a `CoffeeRecord`.
    /// Mirrors `extract_parameters_from_transcript` in `core/analyzer.py`.
    public static func extractParameters(
        transcript: String,
        cameraDevice: String = "iPhone 手机录制",
        sourceType: SourceType = .iphone,
        mediaKind: MediaKind = .video,
        videoPath: String? = nil,
        visualOverrides: VisualFieldReadings? = nil,
        matchedBean: BeanEntry? = nil,
        equipmentDefaults: EquipmentProfile? = nil
    ) -> CoffeeRecord {
        let boundedTranscript = String(transcript.prefix(maxTranscriptLength))
        let safeCameraDevice = AppleOnDeviceMediaRecognizer.sanitizeCaptureDeviceName(cameraDevice) ?? sourceType.displayName
        var rec = CoffeeRecord(
            cameraDevice: safeCameraDevice,
            sourceType: sourceType,
            mediaKind: mediaKind,
            videoPath: videoPath,
            transcript: boundedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let text = normalizeCoffeeText(boundedTranscript)
        let lowerText = text.lowercased()

        // 1. Brew method (冷萃 / 摩卡壶 / 爱乐压 / 法压壶 / 手冲 / Dirty / 澳白 / 拿铁 / 美式 / SOE / 意式浓缩)
        if ["冷萃", "冰滴", "cold brew", "ice drip"].contains(where: { lowerText.contains($0) }) {
            rec.brewMethod = text.contains("冰滴")
                ? "冰滴冷萃 (Ice Drip Cold Brew)"
                : "冷萃咖啡 (Cold Brew)"
        } else if ["摩卡壶", "moka", "bialetti", "brikka"].contains(where: { lowerText.contains($0) }) {
            rec.brewMethod = "摩卡壶 (Moka Pot)"
        } else if ["爱乐压", "aeropress"].contains(where: { lowerText.contains($0) }) {
            rec.brewMethod = "爱乐压 (AeroPress)"
        } else if ["法压壶", "french press"].contains(where: { lowerText.contains($0) }) {
            rec.brewMethod = "法压壶 (French Press)"
        } else if ["滤挂", "挂耳", "drip bag"].contains(where: { lowerText.contains($0) }) {
            rec.brewMethod = "滤挂/挂耳手冲 (Drip Bag Coffee)"
        } else if ["手冲", "pour over", "pourover", "v60", "chemex", "kalita", "滤杯", "手冲壶"].contains(where: { lowerText.contains($0) }) {
            rec.brewMethod = "手冲滴滤 (Pour Over)"
        } else if ["dirty", "脏咖啡"].contains(where: { lowerText.contains($0) }) {
            rec.brewMethod = "意式浓缩基底 · Dirty 咖啡"
        } else if ["澳白", "flat white"].contains(where: { lowerText.contains($0) }) {
            rec.brewMethod = "意式浓缩基底 · 澳白 (Flat White)"
        } else if ["拿铁", "latte", "拉花", "打奶泡", "奶泡", "奶缸", "卡布奇诺", "cappuccino"].contains(where: { lowerText.contains($0) }) {
            rec.brewMethod = "意式浓缩基底 · 冰拿铁/热拿铁"
        } else if ["美式", "americano"].contains(where: { lowerText.contains($0) }) {
            rec.brewMethod = "意式浓缩基底 · 冰美式/热美式"
        } else if ["意式浓缩", "意识浓缩", "浓缩", "espresso", "双份浓缩", "double shot", "soe", "意式"]
            .contains(where: { lowerText.contains($0) }) {
            if lowerText.contains("soe") {
                rec.brewMethod = "SOE 单一产地意式浓缩"
            } else {
                rec.brewMethod = "意式浓缩 (Espresso)"
            }
        } else if [
            "布粉针", "压粉锤", "布粉器", "无底手柄", "手柄", "油脂", "萃取", "蒸汽棒", "变压模式",
            "3828", "格米莱", "gemilai", "geniai", "crm3605", "crm3005", "crm3145", "g3007l",
            "百胜图", "barsetto", "2sap", "bae02s",
            "佩罗奇", "peloqi", "马克西姆", "mokkom", "塞纳",
            "德龙", "de'longhi", "delonghi", "dedica", "ec685", "ec885",
            "米家咖啡机", "小米咖啡机", "portafilter", "crema", "tamper", "breville",
        ].contains(where: { lowerText.contains($0) }) {
            rec.brewMethod = "意式浓缩 (Espresso)"
        } else if ["咖啡机", "咖啡豆", "咖啡"].contains(where: { lowerText.contains($0) }) {
            rec.brewMethod = "意式/日常冲煮"
        }

        // 2. Coffee bean name & roast level
        let beanPatterns = [
            #"(?:还是用|今天用|用了|用的)?(?:这款|这包|这个|那款)([^，。；！\n]{2,18}?)的?(?:咖啡豆|豆子)"#,
            #"(?:还是用|今天用)([^，。；！\n]{2,18}?)的?(?:咖啡豆|豆子)"#,
            #"(?:豆子|咖啡豆)(?:今天)?(?:用的是|用|选的是|是|拿了)([^，。；！\n]{3,28})"#,
            #"(?:今天做|今天冲|今天萃|今天用的是|今天用)(?:的是|一杯)?([^，。；！\n]{2,25}?(?:豆|耶加雪菲|花魁|瑰夏|西达摩|曼特宁|肯尼亚|哥伦比亚|埃塞|拼配|SOE|低因)[^0-9，。；\n]{0,10})"#,
            #"((?:埃塞俄比亚|巴拿马|哥伦比亚|肯尼亚|洪都拉斯|云南|巴西|印尼)[^0-9，。；\n]{2,20})"#,
            #"((?:咸芝士低因|花魁|瑰夏|耶加雪菲|西达摩|天堂庄园|翡翠庄园|栓皮栎|雪莉)[^0-9，。；\n]{0,14})"#,
        ]
        for pattern in beanPatterns {
            if let captured = firstCapture(pattern, in: text) {
                var candidate = replacingMatches(
                    of: #"(?:称重|称豆|克重|磨豆|研磨|浅冲).*$"#,
                    in: captured,
                    with: ""
                )
                candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " ，、的"))
                if candidate.count >= 2 {
                    rec.beanName = candidate
                    break
                }
            }
        }

        if text.contains("中浅烘") || text.contains("中浅冲") {
            rec.beanRoast = "中浅烘焙"
        } else if text.contains("浅烘") || text.contains("浅冲") {
            rec.beanRoast = "浅度烘焙"
        } else if text.contains("中深烘") {
            rec.beanRoast = "中深烘焙"
        } else if text.contains("深烘") || text.contains("深红") {
            rec.beanRoast = "深度烘焙"
        } else if text.contains("中烘") {
            rec.beanRoast = "中度烘焙"
        }

        // 3. Bean weight / ground coffee dose (咖啡豆称重 & 出粉量, CN + EN)
        let weightPatterns = [
            #"(?:咖啡豆|豆子|豆量|出粉量|出粉|接粉|粉量|粉重|称重|称豆|装粉|会用|用了|称了|用|浅烘|浅冲|中烘|深烘|日晒|水洗|厌氧)[^0-9一二两三四五六七八九十，。]{0,12}?([0-9]{1,6}(?:\.[0-9]{1,3})?|[一二两三四五六七八九十点]{1,8})\s*(?:克|课|g|G)"#,
            #"(?<![0-9.])([0-9]{1,6}(?:\.[0-9]{1,3})?)\s*(?:克|课|g|G)\s*(?:的)?\s*(?:咖啡豆|豆子|豆|粉)"#,
            #"(?:瑰夏|花魁|耶加|西达摩|曼特宁|拼配|豆)[^0-9]{0,8}?([0-9]{1,6}(?:\.[0-9]{1,3})?)\s*(?:克|课|g|G)"#,
            #"(?i)(?:dose|dosing|weigh|using|use|with)\s+(?:about\s+)?([0-9]{1,3}(?:\.[0-9]{1,2})?)\s*(?:grams?|g)\b"#,
            #"(?i)(?<![0-9.])([0-9]{1,3}(?:\.[0-9]{1,2})?)\s{0,8}(?:(?:grams?|g)\s{0,8})?(?:in|of\s+(?:coffee|beans|grounds)|dose|coffee)\s{0,6}(?:=|->|→|:)"#,
            #"(?i)(?<![0-9.])([0-9]{1,3}(?:\.[0-9]{1,2})?)\s*(?:grams?|g)\s+(?:in|of\s+(?:coffee|beans|grounds)|dose|coffee)\b"#,
        ]
        for pattern in weightPatterns {
            if let captured = firstCapture(pattern, in: text),
               let val = parseChineseOrDouble(captured),
               val != 0, (5.0...150.0).contains(val) {
                rec.beanWeightG = val
                break
            }
        }
        if rec.beanWeightG == nil,
           let captured = firstCapture(#"(?:咖啡粉|粉量|粉重)(?:设置到|设为|调到|大概|约|是)?\s*([0-9]{2}(?:\.[0-9]{1,2})?)"#, in: text),
           let val = Double(captured), (12.0...25.0).contains(val) {
            rec.beanWeightG = val
        }

        // 4. Grind setting (研磨度刻度, CN + EN)
        let grindPatterns = [
            #"(?:研磨度|刻度|磨豆刻度|刀盘刻度|粗细)(?:调到|设置在|是|用|为|调成)?\s*([0-9]{1,4}(?:\.[0-9]{1,2})?(?:\s*格|\s*圈|\s*档)?|[一二三四五六七八九十点]{1,8}(?:格|档)?)"#,
            #"刻度\s*([0-9]{1,4}(?:\.[0-9]{1,2})?)"#,
            #"(?i)(?:grind\s{0,4}(?:setting|size|number)|setting|dial)\s{0,8}(?:(?:of|at|to|is|:)\s{0,8})?([0-9]{1,3}(?:\.[0-9]{1,2})?)"#,
            #"(?i)(?<![0-9.])([0-9]{1,2})\s*clicks?\b"#,
        ]
        for pattern in grindPatterns {
            if let captured = firstCapture(pattern, in: text) {
                rec.grindSetting = "刻度 \(captured.trimmingCharacters(in: .whitespacesAndNewlines))"
                break
            }
        }

        // 5. Grinder type & model (独立磨豆机 vs 咖啡机自带)
        let externalModels = [
            "Niche Zero", "Niche", "尼斯", "DF64", "DF83", "マイト", "迈赫迪", "EK43",
            "Weber", "EG-1", "Lagom", "P64", "P100", "C40", "司令官", "Eureka",
            "Mignon", "松屋", "巫师", "Kinu", "1Zpresso", "Timemore", "泰摩", "Fellow",
        ]
        let loweredText = text.lowercased()
        var foundModel: String?
        for model in externalModels where loweredText.contains(model.lowercased()) {
            foundModel = model == "尼斯" ? "Niche Zero" : model
            break
        }

        let detectedMachines = extractCoffeeMachineDetections(from: text)
        let builtinMachine = detectedMachines.first(where: { $0.builtinGrinderModel != nil })

        let builtinKeywords = [
            "自带磨豆机", "自带的磨豆机", "咖啡机自带", "内置磨豆机",
            "一体机自带", "自带豆仓", "自带都昌", "3828", "breville", "铂富", "sage", "barsetto", "百胜图",
        ]
        if let foundModel {
            // Explicit external grinder always wins over built-in grinder
            rec.grinderType = "额外独立磨豆机"
            rec.grinderModel = foundModel
        } else if let builtinMachine, let modelName = builtinMachine.builtinGrinderModel {
            rec.grinderType = "咖啡机自带磨豆机"
            rec.grinderModel = modelName
        } else if builtinKeywords.contains(where: { loweredText.contains($0) }) {
            rec.grinderType = "咖啡机自带磨豆机"
            if ["3828", "格米莱", "格莱米"].contains(where: { text.contains($0) }) {
                rec.grinderModel = "格米莱 G3828A (云象One 内置60mm平刀磨豆机)"
            } else if text.contains("铂富") || loweredText.contains("breville") || loweredText.contains("sage") {
                rec.grinderModel = "Breville 铂富内置锥刀磨豆机"
            } else if text.contains("百胜图") || loweredText.contains("barsetto") {
                rec.grinderModel = "Barsetto 百胜图内置磨豆机"
            } else if text.contains("德龙") || loweredText.contains("delonghi") {
                rec.grinderModel = "DeLonghi 德龙内置磨豆机"
            } else {
                rec.grinderModel = "咖啡机内置一体磨豆机"
            }
        } else if ["额外", "独立磨豆机", "外置磨豆机", "单品磨", "独立磨", "外置"]
            .contains(where: { text.contains($0) }) {
            rec.grinderType = "额外独立磨豆机"
            rec.grinderModel = "独立外置专业磨豆机"
        }

        // 6. Yield / liquid output (出液量, CN + EN, incl. ASR homophones 初夜/出夜/初液)
        let yieldPatterns = [
            #"(?:出液量?|初夜|出夜|初液|萃取液|液重|出杯量?|萃出|流出了?|接了|注水|加水)[^0-9一二两三四五六七八九十\n]{0,6}([0-9]{1,6}(?:\.[0-9]{1,3})?|[一二两三四五六七八九十点]{1,8})\s*(?:克|课|毫升|g|G|ml|ML)"#,
            #"(?<![0-9.])([0-9]{1,6}(?:\.[0-9]{1,3})?)\s*(?:克|课|毫升|g|ml)\s*(?:咖啡液|浓缩液|出液|左右自动停止萃取)"#,
            #"(?:萃取|参数)[^0-9\n]{0,12}([0-9]{2,3}(?:\.[0-9]{1,2})?)\s*(?:克|课|g|G|ml|ML)"#,
            #"(?i)(?:=|->|→)\s{0,8}([0-9]{2,4}(?:\.[0-9]{1,2})?)\s{0,8}(?:(?:grams?|g|ml)\s{0,8})?(?:espresso|out|yield|liquid|coffee)\b"#,
            #"(?i)(?:yield|output|extract(?:ing)?|pull(?:ing)?)\s+(?:about\s+)?([0-9]{1,4}(?:\.[0-9]{1,2})?)\s*(?:grams?|g|ml)\b"#,
            #"(?i)(?<![0-9.])([0-9]{1,4}(?:\.[0-9]{1,2})?)\s*(?:grams?|g|ml)\s+(?:out|of\s+(?:espresso|liquid|coffee|yield)|yield)\b"#,
        ]
        for pattern in yieldPatterns {
            if let captured = firstCapture(pattern, in: text),
               let val = parseChineseOrDouble(captured),
               val != 0, (10.0...1500.0).contains(val) {
                rec.yieldG = val
                break
            }
        }

        // 7. Extraction time (seconds for espresso/pour-over, hours for cold brew, CN + EN)
        let hourCapture = firstCapture(
            #"(?i)(?:萃取|浸泡|冷藏|时间|steep|brew)[^0-9]{0,6}([0-9]{1,4}(?:\.[0-9]{1,2})?)\s*(?:小时|hours?|hrs?|h)\b"#,
            in: text
        )
        var secCapture = firstCapture(
            #"(?:萃取时间|萃取了?|耗时|读秒|用了|时间是?|控制在|大约|大概|总共|一共)[^0-9一二两三四五六七八九十]{0,6}([0-9]{1,5}(?:\.[0-9]{1,2})?|[一二两三四五六七八九十]{1,6})\s*(?:秒|s|S)"#,
            in: text
        )
        if secCapture == nil {
            secCapture = firstCapture(
                #"(?<![0-9.])([0-9]{2}(?:\.[0-9]{1,2})?)\s*(?:秒|s)\s*(?:出液|初夜|出夜|结束|完成|停|以内|左右)"#,
                in: text
            )
        }
        if secCapture == nil {
            // English range like "25-30 seconds" / "25 to 30 seconds" -> bounded linear match without optional prefix backtracking
            if let rangeFirst = firstCapture(#"(?i)(?<![0-9.])([0-9]{2})\s{0,4}(?:-|to|~|–)\s{0,4}([0-9]{2})\s{0,6}(?:seconds?|secs?|s)\b"#, in: text) {
                secCapture = rangeFirst
            } else {
                secCapture = firstCapture(
                    #"(?i)(?:total\s+time|extraction\s+time|brew\s+time|shot\s+time|in|for|around|about|takes?)\s{0,6}(?::\s{0,6})?([0-9]{2,3}(?:\.[0-9]{1,2})?)\s{0,6}(?:seconds?|secs?)\b"#,
                    in: text
                )
            }
        }
        if secCapture == nil, rec.brewMethod != nil {
            // Fallback for spoken espresso timer readings like "20.1秒" or "28秒"
            if let bareSec = firstCapture(#"(?<![0-9.])([1-5][0-9](?:\.[0-9]{1,2})?)\s*(?:秒)"#, in: text),
               let val = Double(bareSec), (15.0...60.0).contains(val) {
                secCapture = bareSec
            }
        }
        if let secCapture {
            rec.extractionTimeS = parseChineseOrDouble(secCapture)
        } else if let hourCapture, let hours = parseChineseOrDouble(hourCapture), hours != 0 {
            rec.extractionTimeS = pyRound(hours * 3600, 1)
        }

        // 8. Pressure (incl. ASR homophones 酒八/九八 → 9bar)
        let normPressureText = text
            .replacingOccurrences(of: "酒八", with: "9bar")
            .replacingOccurrences(of: "九八", with: "9bar")
        var pressureCapture = firstCapture(
            #"(?:压力表?|萃取压力|峰值压力|压力)(?:稳定在|在|是|达到|为)?\s*([0-9]{1,4}(?:\.[0-9]{1,2})?|[一二三四五六七八九十点]{1,6})\s*(?:bar|Bar|BAR|帕|巴|霸|八)"#,
            in: normPressureText
        )
        if pressureCapture == nil {
            pressureCapture = firstCapture(
                #"(?i)(?<![0-9.])([0-9]{1,2}(?:\.[0-9]{1,2})?)\s*(?:bars?|巴|霸)\b"#,
                in: normPressureText
            )
        }
        if let pressureCapture {
            rec.pressureBar = parseChineseOrDouble(pressureCapture)
        }

        // 9. Water temperature (CN + EN °C and °F)
        if let tempCapture = firstCapture(
            #"(?:水温|萃取温度|温度)[^0-9]{0,4}([0-9]{1,4}(?:\.[0-9]{1,2})?)\s*(?:度|°C|℃|C)"#,
            in: text
        ) {
            rec.waterTempC = Double(tempCapture)
        } else if let tempC = firstCapture(#"(?i)(?<![0-9.])(8[0-9]|9[0-9]|100)(?:\.[0-9])?\s*(?:°\s*c|℃|degrees?\s*celsius)\b"#, in: text),
                  let val = Double(tempC) {
            rec.waterTempC = val
        } else if let tempF = firstCapture(#"(?i)(?<![0-9.])(19[0-9]|20[0-9]|21[0-2])\s*(?:°\s*f|degrees?\s*fahrenheit)\b"#, in: text),
                  let fVal = Double(tempF) {
            rec.waterTempC = pyRound((fVal - 32.0) * 5.0 / 9.0, 1)
        }

        // Bean-library shorthand match (e.g. "今天用花魁" → full origin, roast, flavor tags).
        if let bean = matchedBean {
            if !bean.fullName.isEmpty { rec.beanName = bean.fullName }
            if isNilOrEmpty(rec.beanRoast), !bean.roastLevel.isEmpty {
                rec.beanRoast = bean.roastLevel
            }
            // Python gates grind auto-fill behind `_auto_fill_bean_grind`, which the
            // ingestion pipeline never sets — keep the same effective behavior here.
            if !bean.flavorTags.isEmpty { rec.flavorNotes = bean.flavorTags }
        }

        // Visual scale / gauge readings fill fields the transcript left empty (before permanent defaults).
        if let visual = visualOverrides {
            if rec.beanName == nil, let v = visual.beanName { rec.beanName = v }
            if rec.beanWeightG == nil, let v = visual.beanWeightG { rec.beanWeightG = v }
            if rec.grindSetting == nil, let v = visual.grindSetting { rec.grindSetting = v }
            if rec.grinderModel == nil, let v = visual.grinderModel { rec.grinderModel = v }
            if rec.pressureBar == nil, let v = visual.pressureBar { rec.pressureBar = v }
            if rec.waterTempC == nil, let v = visual.waterTempC { rec.waterTempC = v }
            if rec.yieldG == nil, let v = visual.yieldG { rec.yieldG = v }
            if rec.extractionTimeS == nil, let v = visual.extractionTimeS { rec.extractionTimeS = v }
        }

        // Permanent equipment defaults (auto-fill grinder & water temp when neither transcript nor visual OCR specified them).
        if let defaults = equipmentDefaults, defaults.autoFillDefaultGrinder {
            if isNilOrEmpty(rec.grinderType) {
                rec.grinderType = defaults.defaultGrinderType.isEmpty ? "额外独立磨豆机" : defaults.defaultGrinderType
            }
            if isNilOrEmpty(rec.grinderModel) {
                rec.grinderModel = defaults.defaultGrinderModel.isEmpty ? "Niche Zero (63mm 锥刀)" : defaults.defaultGrinderModel
            }
            if (rec.waterTempC ?? 0) == 0, defaults.defaultWaterTempC != 0 {
                rec.waterTempC = defaults.defaultWaterTempC
            }
        }

        rec.computeDerivedMetrics()
        if isEquipmentIntroduction(transcript: boundedTranscript, record: rec) {
            rec.recordType = .equipmentProfile
            rec.equipmentItems = extractEquipmentItems(from: boundedTranscript)
            if isNilOrEmpty(rec.brewMethod) {
                rec.brewMethod = "常驻设备与器具档案补充"
            }
            if isNilOrEmpty(rec.beanName) {
                rec.beanName = "\(nonEmpty(rec.grinderModel) ?? "居家咖啡机") · 全套器具建档"
            }
            rec.computeDerivedMetrics()
        }
        enrichBaristaAnalysis(&rec)
        return rec
    }

    // MARK: - Equipment introduction classification

    private static let equipmentIntroKeywords = [
        "器具", "工具", "配件", "压粉锤", "鸭粉锤", "阿粪吹", "牙粪吹", "压粉", "布粉器", "布粉针",
        "部分器", "部分锤", "部分针", "接粉环", "集粉环", "基本环", "吸尘器", "清洁工具", "清洁刷",
        "吹粉", "豆勺", "粉杯", "转换", "一次性杯", "手柄", "双杯", "双碑", "滤纸", "一整套",
        "介绍", "看看我们的咖啡机", "自带豆仓", "自带都昌", "电子秤", "敲渣盒", "粉渣盒",
        "一机全包", "全方位", "咖啡角", "设备升级", "开箱", "测评",
    ]

    private static let equipmentAccessoryCatalog: [(keywords: [String], item: EquipmentItem)] = [
        (
            ["3828", "3200", "格米莱", "格莱米", "可爱米", "咖啡机", "自带豆仓", "自带都昌"],
            EquipmentItem(
                id: "eq-gemilai-g3828a",
                name: "格米莱 G3828A (云象One 研磨一体咖啡机)",
                category: "主力咖啡机 & 内置磨豆机",
                spec: "内置 60mm 不锈钢平刀磨豆机 + 200g 顶部豆仓 + 58mm 商用冲煮头",
                role: "研磨萃取一体，提供稳定 9 bar 泵压与 93°C 恒温萃取"
            )
        ),
        (
            ["压粉锤", "鸭粉锤", "压吹", "鸭吹", "阿粪吹", "牙粪吹", "自动回弹", "自动回答", "轰炸机"],
            EquipmentItem(
                id: "eq-mhw-tamper",
                name: "MHW-3BOMBER 轰炸机 58.35mm 自适应恒力压粉锤",
                category: "压粉器具 (自动回弹)",
                spec: "58.35mm 精密螺纹底座 · 30lbs 恒压自动回弹",
                role: "保证每次压粉力度垂直均匀，避免粉饼倾斜导致偏流"
            )
        ),
        (
            ["布粉器", "部分器", "部分锤", "桨式", "布粉"],
            EquipmentItem(
                id: "eq-distributor",
                name: "MHW-3BOMBER 58.35mm 自适应四桨布粉器 & 格米莱原装压粉锤",
                category: "布粉 & 压粉器具",
                spec: "58mm 粉碗平整布粉 + 胡桃木/金属原装压粉锤",
                role: "在压粉前快速找平粉层表面，减少表面密度不均"
            )
        ),
        (
            ["布粉针", "部分针", "接粉环", "基本环"],
            EquipmentItem(
                id: "eq-dosing-wdt",
                name: "58mm 磁吸接粉环 + WDT 针式布粉器",
                category: "接粉 & 破块器具",
                spec: "铝合金磁吸防飞粉接粉环 + 细针破块器",
                role: "接粉防洒并打散研磨结块，大幅降低萃取通道效应"
            )
        ),
        (
            ["手柄", "双杯", "双碑"],
            EquipmentItem(
                id: "eq-portafilter",
                name: "格米莱 G3828A 58mm 实木双嘴分流手柄",
                category: "萃取手柄 & 粉碗",
                spec: "58mm 双份增压/非增压双嘴手柄 (建议粉量 17-19g)",
                role: "双嘴均匀分流出品，支持单份/双份意式浓缩基底萃取"
            )
        ),
        (
            ["滤纸", "分水网"],
            EquipmentItem(
                id: "eq-filter-paper",
                name: "58mm 意式粉碗丸型滤纸",
                category: "过滤耗材",
                spec: "58mm 底部/顶部通用丸型滤纸",
                role: "阻隔极细粉穿透粉碗底孔，提升油脂干净度并保持冲煮头清洁"
            )
        ),
        (
            ["吸尘器", "清洁", "清洁刷", "气吹", "吹粉", "敲渣"],
            EquipmentItem(
                id: "eq-vacuum-cleaner",
                name: "桌面便携式电动咖啡粉吸尘器 & 胡桃木压粉底座/粉渣盒",
                category: "吧台清洁与收纳",
                spec: "无线桌面吸尘器 + 实木多槽压粉收纳底座",
                role: "随时清理磨豆机残粉与台面咖啡渣，保持居家咖啡角整洁"
            )
        ),
        (
            ["一次性杯", "出品杯", "纸杯", "电子秤", "粉杯", "豆勺"],
            EquipmentItem(
                id: "eq-cups-scale",
                name: "意式电子计时咖啡秤 + 居家出品纸杯/拉花杯组",
                category: "称量与出品杯具",
                spec: "0.1g 精度电子咖啡秤 + 隔热瓦楞一次性出品杯",
                role: "精准监测称豆粉重与浓缩出液流速，方便日常打卡与外带分享"
            )
        ),
    ]

    /// Returns true when a recording introduces home coffee equipment/tools without
    /// performing an actual extraction (no dose weight, yield, time, pressure, or grind).
    public static func isEquipmentIntroduction(transcript: String, record: CoffeeRecord) -> Bool {
        if record.recordType == .equipmentProfile { return true }
        let source = transcript.isEmpty ? record.transcript : transcript
        let text = normalizeCoffeeText(source).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return false }

        let hasRealPressure = (record.pressureBar ?? 0) > 1.0
        let hasActualBrewMetrics = record.beanWeightG != nil
            || record.yieldG != nil
            || record.extractionTimeS != nil
            || hasRealPressure
            || record.grindSetting != nil
        if hasActualBrewMetrics { return false }

        let kwHits = equipmentIntroKeywords.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
        let explicitIntro = [
            "来看看我们的咖啡机",
            "介绍相应的所有我们",
            "这就是我们这一整套的咖啡制作的工具",
            "做咖啡的器具",
            "咖啡制作的工具",
            "今天先介绍",
            "专业配件全方位",
            "一机全包",
            "咖啡角设备",
        ].contains { text.contains($0) }
        return explicitIntro || kwHits >= 2
    }

    /// Matches bar accessories (tamper, distributor, WDT, dosing ring, portafilter,
    /// filter paper, vacuum, cups/scale) against the catalog; falls back to the first
    /// five core items when the transcript is non-empty but nothing matched.
    public static func extractEquipmentItems(from transcript: String) -> [EquipmentItem] {
        let matched = extractMentionedEquipmentItems(from: transcript)
        if !matched.isEmpty {
            return matched
        }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return equipmentAccessoryCatalog.prefix(5).map(\.item)
        }
        return []
    }

    // MARK: - 6-Brand Espresso Machine Catalog & Extractor

    private struct CoffeeMachineDetection {
        let item: EquipmentItem
        let builtinGrinderModel: String?
    }

    private static func containsWord(_ word: String, in loweredText: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        let pattern = #"(?<![a-z0-9])"# + escaped + #"(?![a-z0-9])"#
        return firstCapture("(" + pattern + ")", in: loweredText) != nil
    }

    /// Detects the 6 major consumer espresso machine brands & models from normalized
    /// transcript + OCR text (Barsetto 百胜图, Xiaomi/Mijia 小米/米家, Gemilai 格米莱,
    /// PELOQI 佩罗奇/佩洛奇, MOKKOM 马克西姆, De'Longhi 德龙).
    private static func extractCoffeeMachineDetections(from rawText: String) -> [CoffeeMachineDetection] {
        let text = normalizeCoffeeText(rawText)
        let lowered = text.lowercased()
        guard !lowered.isEmpty else { return [] }

        var detections: [CoffeeMachineDetection] = []
        var seenIDs = Set<String>()

        func append(_ item: EquipmentItem, builtinGrinder: String? = nil) {
            if seenIDs.insert(item.id).inserted {
                detections.append(CoffeeMachineDetection(item: item, builtinGrinderModel: builtinGrinder))
            }
        }

        let hasCoffeeContext = ["咖啡", "意式", "浓缩", "拿铁", "拉花", "奶泡", "萃取", "手柄", "蒸汽", "磨豆", "机器", "espresso", "latte", "coffee"]
            .contains(where: { lowered.contains($0) })

        // 1. 百胜图 (Barsetto)
        let hasBarsettoBrand = text.contains("百胜图") || lowered.contains("barsetto")
        if hasBarsettoBrand
            || lowered.contains("2sap")
            || lowered.contains("bae02s")
            || lowered.contains("bae02")
            || lowered.contains("bae01") {
            let model: String
            let isIntegrated: Bool
            if lowered.contains("2sap") || lowered.contains("bae02s") {
                model = "2sAP (BAE02S)"
                isIntegrated = true
            } else if lowered.contains("bae02") {
                model = "BAE02"
                isIntegrated = true
            } else if lowered.contains("bae01") {
                model = "BAE01"
                isIntegrated = true
            } else if hasBarsettoBrand && containsWord("3s", in: lowered) {
                model = "3S"
                isIntegrated = true
            } else if hasBarsettoBrand && lowered.contains("m2v") {
                model = "M2V"
                isIntegrated = true
            } else if hasBarsettoBrand && containsWord("v1", in: lowered) {
                model = "V1"
                isIntegrated = false
            } else {
                model = ""
                isIntegrated = text.contains("一体") || text.contains("自带") || text.contains("研磨")
            }
            let suffix = model.isEmpty ? "" : " \(model)"
            let name = isIntegrated
                ? "百胜图\(suffix) (Barsetto 研磨一体咖啡机)"
                : "百胜图\(suffix) (Barsetto 意式咖啡机)"
            append(
                EquipmentItem(
                    id: "eq-machine-barsetto\(model.isEmpty ? "" : "-" + model.lowercased().replacingOccurrences(of: " ", with: "-"))",
                    name: name,
                    category: isIntegrated ? "主力咖啡机 & 内置磨豆机" : "主力咖啡机",
                    spec: isIntegrated ? "Barsetto 百胜图研磨一体半自动意式咖啡机" : "Barsetto 百胜图半自动意式咖啡机",
                    role: "意式浓缩萃取与蒸汽打奶泡主机"
                ),
                builtinGrinder: isIntegrated ? "百胜图\(suffix) 内置磨豆机 (Barsetto)" : nil
            )
        }

        // 2. 小米 / 米家半自动意式咖啡机 (Xiaomi / Mijia)
        let hasXiaomiExplicit = text.contains("米家")
            || lowered.contains("mijia")
            || lowered.contains("xiaomi")
            || text.contains("小米咖啡机")
            || text.contains("小米半自动")
            || (text.contains("小米") && hasCoffeeContext)
        if hasXiaomiExplicit {
            append(
                EquipmentItem(
                    id: "eq-machine-xiaomi-mijia",
                    name: "米家半自动意式咖啡机 (Xiaomi Mijia Espresso Machine)",
                    category: "主力咖啡机",
                    spec: "小米/米家 20Bar 紧凑型半自动意式咖啡机 · 触控面板 + 旋转蒸汽棒",
                    role: "居家日常意式浓缩萃取与拿铁打奶泡"
                ),
                builtinGrinder: nil
            )
        }

        // 3. 格米莱 (Gemilai)
        let hasGemilaiBrand = text.contains("格米莱") || lowered.contains("gemilai") || lowered.contains("geniai")
        if hasGemilaiBrand
            || lowered.contains("3828")
            || lowered.contains("crm3605")
            || lowered.contains("crm3005")
            || lowered.contains("crm3145")
            || lowered.contains("g3007l")
            || lowered.contains("3149")
            || text.contains("自带豆仓")
            || text.contains("自带都昌") {
            if lowered.contains("3828") || lowered.contains("3200") || text.contains("自带豆仓") || text.contains("自带都昌") {
                append(
                    EquipmentItem(
                        id: "eq-gemilai-g3828a",
                        name: "格米莱 G3828A (云象One 研磨一体咖啡机)",
                        category: "主力咖啡机 & 内置磨豆机",
                        spec: "内置 60mm 不锈钢平刀磨豆机 + 200g 顶部豆仓 + 58mm 商用冲煮头",
                        role: "研磨萃取一体，提供稳定 9 bar 泵压与 93°C 恒温萃取"
                    ),
                    builtinGrinder: "格米莱 G3828A (云象One 内置60mm平刀磨豆机)"
                )
            } else {
                let model: String
                if lowered.contains("crm3605") || (hasGemilaiBrand && lowered.contains("3605")) {
                    model = "CRM3605"
                } else if lowered.contains("crm3005") || (hasGemilaiBrand && lowered.contains("3005")) {
                    model = "CRM3005"
                } else if lowered.contains("crm3145") || (hasGemilaiBrand && lowered.contains("3145")) {
                    model = "CRM3145"
                } else if lowered.contains("g3007l") || (hasGemilaiBrand && lowered.contains("3007")) {
                    model = "G3007L"
                } else if lowered.contains("3149") {
                    model = "CRM3149"
                } else {
                    model = ""
                }
                let suffix = model.isEmpty ? "" : " \(model)"
                append(
                    EquipmentItem(
                        id: "eq-machine-gemilai\(model.isEmpty ? "" : "-" + model.lowercased())",
                        name: "格米莱\(suffix) (Gemilai 半自动意式咖啡机)",
                        category: "主力咖啡机",
                        spec: "Gemilai 格米莱\(suffix) 58mm 半自动意式浓缩咖啡机",
                        role: "意式浓缩稳定萃取与蒸汽打奶泡"
                    ),
                    builtinGrinder: nil
                )
            }
        }

        // 4. 佩罗奇 / 佩洛奇 (PELOQI)
        let hasPeloqiBrand = text.contains("佩罗奇") || lowered.contains("peloqi")
        if hasPeloqiBrand {
            let model: String
            let isIntegrated: Bool
            if containsWord("s1", in: lowered) || lowered.contains("佩罗奇s1") {
                model = "S1"
                isIntegrated = true
            } else if containsWord("s2", in: lowered) || lowered.contains("佩罗奇s2") {
                model = "S2"
                isIntegrated = text.contains("一体") || text.contains("研磨")
            } else if containsWord("s3", in: lowered) || lowered.contains("佩罗奇s3") {
                model = "S3"
                isIntegrated = text.contains("一体") || text.contains("研磨")
            } else if containsWord("k6", in: lowered) || lowered.contains("佩罗奇k6") {
                model = "K6"
                isIntegrated = false
            } else {
                model = ""
                isIntegrated = text.contains("一体") || text.contains("研磨")
            }
            let suffix = model.isEmpty ? "" : " \(model)"
            let name = isIntegrated
                ? "佩罗奇\(suffix) 研磨一体咖啡机 (PELOQI\(suffix))"
                : "佩罗奇\(suffix) (PELOQI 意式咖啡机)"
            append(
                EquipmentItem(
                    id: "eq-machine-peloqi\(model.isEmpty ? "" : "-" + model.lowercased())",
                    name: name,
                    category: isIntegrated ? "主力咖啡机 & 内置磨豆机" : "主力咖啡机",
                    spec: isIntegrated ? "PELOQI 佩罗奇\(suffix) 研磨一体半自动意式咖啡机" : "PELOQI 佩罗奇\(suffix) 半自动意式咖啡机",
                    role: "研磨萃取与双系统打奶泡主机"
                ),
                builtinGrinder: isIntegrated ? "佩罗奇\(suffix) 内置磨豆机 (PELOQI\(suffix))" : nil
            )
        }

        // 5. 马克西姆 (MOKKOM)
        let hasMokkomBrand = text.contains("马克西姆") || lowered.contains("mokkom")
        let hasMokkomSeries = (text.contains("塞纳") || lowered.contains("seine") || text.contains("马赛") || text.contains("鲶鱼") || text.contains("巴洛克"))
            && (hasMokkomBrand || hasCoffeeContext)
        if hasMokkomBrand || hasMokkomSeries {
            let series: String
            if text.contains("塞纳") || lowered.contains("seine") {
                series = "塞纳 (MOKKOM Seine)"
            } else if text.contains("马赛") {
                series = "马赛 (MOKKOM)"
            } else if text.contains("鲶鱼") {
                series = "鲶鱼 (MOKKOM)"
            } else if text.contains("巴洛克") {
                series = "巴洛克 (MOKKOM)"
            } else {
                series = "(MOKKOM)"
            }
            let isIntegrated = text.contains("一体机") || text.contains("自带磨豆机") || text.contains("内置磨豆机")
            append(
                EquipmentItem(
                    id: "eq-machine-mokkom",
                    name: "马克西姆\(series) 意式咖啡机",
                    category: isIntegrated ? "主力咖啡机 & 内置磨豆机" : "主力咖啡机",
                    spec: "MOKKOM 马克西姆\(series) 变压/半自动意式咖啡机",
                    role: "多模式变压萃取与强劲蒸汽打奶泡"
                ),
                builtinGrinder: isIntegrated ? "马克西姆\(series) 内置磨豆机" : nil
            )
        }

        // 6. 德龙 (De'Longhi)
        let hasDelonghiBrand = text.contains("德龙")
            || lowered.contains("de'longhi")
            || lowered.contains("delonghi")
            || lowered.contains("dedica")
            || lowered.contains("ec685")
            || lowered.contains("ec885")
            || lowered.contains("ec9355")
            || lowered.contains("ec9865")
        if hasDelonghiBrand {
            let model: String
            let isIntegrated: Bool
            if lowered.contains("ec685") {
                model = "Dedica EC685"
                isIntegrated = false
            } else if lowered.contains("ec885") {
                model = "Dedica Arte EC885"
                isIntegrated = false
            } else if lowered.contains("ec9355") {
                model = "La Specialista EC9355"
                isIntegrated = true
            } else if lowered.contains("ec9865") {
                model = "La Specialista Maestro EC9865"
                isIntegrated = true
            } else if lowered.contains("dedica") {
                model = "Dedica"
                isIntegrated = false
            } else {
                model = ""
                isIntegrated = text.contains("一体机") || text.contains("自带磨豆机")
            }
            let suffix = model.isEmpty ? "" : " \(model)"
            append(
                EquipmentItem(
                    id: "eq-machine-delonghi\(model.isEmpty ? "" : "-" + model.lowercased().replacingOccurrences(of: " ", with: "-"))",
                    name: "德龙\(suffix) (De'Longhi 意式咖啡机)",
                    category: isIntegrated ? "主力咖啡机 & 内置磨豆机" : "主力咖啡机",
                    spec: isIntegrated ? "De'Longhi 德龙\(suffix) 研磨一体意式咖啡机" : "De'Longhi 德龙\(suffix) 半自动意式咖啡机",
                    role: "意式浓缩萃取与蒸汽打奶泡拉花"
                ),
                builtinGrinder: isIntegrated ? "德龙\(suffix) 内置磨豆机 (De'Longhi)" : nil
            )
        }

        return detections
    }

    /// Strictly extracts only equipment/accessories explicitly mentioned in the transcript
    /// (after Traditional-to-Simplified & ASR homophone normalization), returning empty when none are mentioned.
    public static func extractMentionedEquipmentItems(from transcript: String) -> [EquipmentItem] {
        let normalized = normalizeCoffeeText(transcript)
            .replacingOccurrences(of: "基本环", with: "接粉环")
            .replacingOccurrences(of: "绿子", with: "滤纸")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let lowered = normalized.lowercased()
        var matched: [EquipmentItem] = []
        var seenIDs = Set<String>()

        // 1. First extract any recognized coffee machines (6 major brands & models)
        let detectedMachines = extractCoffeeMachineDetections(from: normalized)
        for det in detectedMachines {
            if seenIDs.insert(det.item.id).inserted {
                matched.append(det.item)
            }
        }

        // 2. Then extract bar accessories; skip the legacy generic "咖啡机" -> Gemilai G3828A
        //    mapping when a specific coffee machine brand was already identified, and avoid
        //    branding another machine's portafilter as Gemilai G3828A.
        let hasNonG3828AMachine = detectedMachines.contains { $0.item.id != "eq-gemilai-g3828a" }
        for entry in equipmentAccessoryCatalog {
            if entry.item.id == "eq-gemilai-g3828a" {
                if !detectedMachines.isEmpty { continue }
                let strictGemilaiKeywords = ["3828", "3200", "格米莱", "自带豆仓", "自带都昌"]
                if strictGemilaiKeywords.contains(where: { lowered.contains($0.lowercased()) }) {
                    if seenIDs.insert(entry.item.id).inserted {
                        matched.append(entry.item)
                    }
                }
                continue
            }
            if entry.keywords.contains(where: { lowered.contains($0.lowercased()) }) {
                if entry.item.id == "eq-portafilter" && hasNonG3828AMachine {
                    let isBottomless = normalized.contains("无底手柄") || lowered.contains("bottomless")
                    let genericPortafilter = EquipmentItem(
                        id: "eq-portafilter",
                        name: isBottomless ? "58mm 无底意式萃取手柄" : "58mm 意式萃取手柄",
                        category: "萃取手柄 & 粉碗",
                        spec: isBottomless ? "58mm 无底萃取手柄 (便于观察油脂与流速)" : "58mm 意式半自动萃取手柄",
                        role: "装填粉饼并锁紧冲煮头完成意式浓缩萃取"
                    )
                    if seenIDs.insert(genericPortafilter.id).inserted {
                        matched.append(genericPortafilter)
                    }
                } else if seenIDs.insert(entry.item.id).inserted {
                    matched.append(entry.item)
                }
            }
        }
        return matched
    }

    // MARK: - Equipment keyframe relabeling

    private static let equipmentStagePlan: [(badge: String, title: String, description: String)] = [
        (
            "E1 压粉与布粉台",
            "MHW-3BOMBER 自动回弹压粉锤 · 布粉器 · 实木压粉底座",
            "实拍咖啡角器具特写：MHW-3BOMBER 轰炸机恒力自动回弹压粉锤、四桨布粉器与胡桃木收纳底座"
        ),
        (
            "E2 配件与清洁工具",
            "58mm 接粉环 · 针式布粉器 · 原装木柄压粉锤 · 桌面吸尘器 · 出品纸杯",
            "实拍吧台配件架：58mm 磁吸接粉环、WDT 布粉针、格米莱原装木柄压粉锤、便携吸尘器与一次性出品杯"
        ),
        (
            "E3 咖啡机与手柄",
            "格米莱 G3828A 研磨一体咖啡机 · 58mm 双嘴手柄与丸型滤纸",
            "实拍主机与冲煮头：格米莱 G3828A (云象One 自带豆仓研磨一体机)、双嘴实木手柄与 58mm 粉碗滤纸"
        ),
        (
            "E4 咖啡角与常驻豆",
            "居家咖啡角全景 · RARAKIDDO 咸芝士低因 SOE 咖啡豆",
            "实拍居家咖啡角全景：格米莱 G3828A 主机、全套压粉布粉工具架与 RARAKIDDO 咸芝士低因 SOE 豆袋"
        ),
    ]

    /// Replaces brewing-specific keyframe titles (P1 称豆 / P2 刻度 / P3 压力表 / P4 出杯)
    /// with equipment & workstation showcase titles for equipment-profile records.
    public static func relabelKeyframesForEquipmentProfile(
        _ keyframes: [KeyframeObservation],
        items: [EquipmentItem]
    ) -> [KeyframeObservation] {
        keyframes.enumerated().map { idx, keyframe in
            var updated = keyframe
            let plan = equipmentStagePlan[min(idx, equipmentStagePlan.count - 1)]
            updated.presetBadge = plan.badge
            updated.stage = plan.title
            updated.visualDescription = plan.description
            return updated
        }
    }

    // MARK: - Barista analysis & social copy

    /// Generates barista diagnosis, flavor profile, timeline events, next-brew suggestions,
    /// and Xiaohongshu / WeChat copy. Never fabricates extraction metrics when they are
    /// missing or when the recording is an equipment introduction.
    public static func enrichBaristaAnalysis(_ record: inout CoffeeRecord) {
        if record.recordType == .equipmentProfile
            || isEquipmentIntroduction(transcript: record.transcript, record: record) {
            enrichEquipmentProfile(&record)
            return
        }

        let isColdBrew = record.brewMethod?.contains("冷萃") == true
        let isPourOver = record.brewMethod?.contains("手冲") == true || record.brewMethod?.contains("滤挂") == true
        let isMokaPot = record.brewMethod?.contains("摩卡壶") == true
        let isAeroOrFrench = record.brewMethod?.contains("爱乐压") == true || record.brewMethod?.contains("法压壶") == true
        let hasCoreEspressoMetrics = record.beanWeightG != nil
            && record.yieldG != nil
            && record.extractionTimeS != nil
        let weight = record.beanWeightG ?? (isColdBrew ? 50.0 : (isPourOver ? 15.0 : 18.0))
        let yieldG = record.yieldG ?? (isColdBrew ? 500.0 : (isPourOver ? 225.0 : 36.0))
        let ratio = weight > 0 ? pyRound(yieldG / weight, 2) : (isPourOver ? 15.0 : 2.0)
        let timeS = record.extractionTimeS ?? (isColdBrew ? 43200.0 : (isPourOver ? 135.0 : 28.0))
        let pressure = record.pressureBar ?? (isColdBrew || isPourOver || isAeroOrFrench ? 1.0 : (isMokaPot ? 2.0 : 9.0))

        var suggestions: [String] = []
        var flavor = FlavorProfile()

        if isColdBrew {
            let hours = pyRound(timeS / 3600.0, 1)
            record.extractionDiagnosis =
                "本次\(record.brewMethod ?? "")采用粉水比 1:\(floatStr(ratio))，低温慢速浸泡约 \(floatStr(hours)) 小时。"
                + "使用\(nonEmpty(record.grinderType) ?? "独立磨豆机")（\(nonEmpty(record.grindSetting) ?? "中粗研磨")）有效避免了细粉过萃带来的杂涩感，"
                + "花果香气与干净度表现极佳。"
            flavor = FlavorProfile(acidity: 7.8, sweetness: 8.6, body: 6.8, aroma: 8.9, aftertaste: 8.4, balance: 8.5)
            record.flavorNotes = ["茉莉花香", "水蜜桃汁", "柑橘蜜甜", "丝滑冷冽尾韵"]
            let tightened = max(7.0, pyRound(ratio - 1.5, 1))
            suggestions = [
                "【粉水比微调】当前粉水比为 1:\(floatStr(ratio))，若直接加冰块饮用，建议下次将粉水比收紧至 1:\(floatStr(tightened))，冰块融化后浓度更饱满。",
                "【研磨度建议】使用 \(nonEmpty(record.grinderModel) ?? "磨豆机") 时，可在装粉前用筛粉器简单筛去极细粉（<200μm），冷萃液透亮度还能提升一个台阶。",
                "【熟成风味】过滤出液后建议在冰箱密封静置熟成 12 小时再饮用，发酵果香与威士忌般的甜感会更加圆润。",
            ]
        } else if isPourOver && hasCoreEspressoMetrics {
            let tempDisp = record.waterTempC.map { "\(floatStr($0))°C" } ?? "92°C"
            record.extractionDiagnosis =
                "本次\(record.brewMethod ?? "手冲滴滤")实测粉重 \(floatStr(weight))g，注水/出液 \(floatStr(yieldG))g（粉水比 1:\(floatStr(ratio))），水温 \(tempDisp)，耗时 \(safeInt(timeS))s。"
                + "分段注水与流速控制清晰，风味干净度与层次感表现良好。"
            flavor = FlavorProfile(acidity: 8.2, sweetness: 8.4, body: 7.0, aroma: 8.8, aftertaste: 8.3, balance: 8.5)
            if record.flavorNotes.isEmpty {
                record.flavorNotes = ["柑橘清香", "蜂蜜甜感", "干净茶感", "柔和回甘"]
            }
            suggestions = [
                "【闷蒸与分段注水】建议前 30 秒以约 \(floatStr(pyRound(weight * 2.0, 0)))g 热水充分闷蒸排气，再分两至三段中心画圈注水至目标粉水比 1:15~1:16。",
                "【水温与研磨配合】浅烘豆可维持 91~93°C 激发花果香，中深烘豆建议降至 87~89°C 避免尾段焦苦。",
            ]
        } else if isMokaPot && hasCoreEspressoMetrics {
            record.extractionDiagnosis =
                "本次摩卡壶冲煮粉重 \(floatStr(weight))g，出液 \(floatStr(yieldG))g（比例 1:\(floatStr(ratio))），耗时 \(safeInt(timeS))s，蒸汽微压萃取带来浓郁焦糖与醇厚口感。"
            flavor = FlavorProfile(acidity: 6.8, sweetness: 8.1, body: 8.6, aroma: 8.4, aftertaste: 8.0, balance: 8.1)
            if record.flavorNotes.isEmpty {
                record.flavorNotes = ["黑巧克力", "焦糖坚果", "浓郁醇厚"]
            }
            suggestions = [
                "【下壶注水与控火】下壶注温水不超过泄压阀下沿，全程中小火加热，听到嘶嘶喷汽前及时离火降温，避免过萃焦苦。",
                "【装粉手法】粉槽自然填平轻震即可，切勿像意式手柄那样重压，确保蒸汽顺畅穿透粉层。",
            ]
        } else if !hasCoreEspressoMetrics {
            // Honest diagnosis when core metrics were not captured — never fabricate
            // 18g → 36g / 28s / 9.0 bar defaults.
            var capturedParts: [String] = []
            if let beanName = nonEmpty(record.beanName) {
                capturedParts.append("咖啡豆「\(beanName)」")
            }
            if let w = record.beanWeightG { capturedParts.append("粉重 \(floatStr(w))g") }
            if let y = record.yieldG { capturedParts.append("出液 \(floatStr(y))g") }
            if let t = record.extractionTimeS { capturedParts.append("耗时 \(safeInt(t))s") }
            if let p = record.pressureBar { capturedParts.append("压力 \(floatStr(p)) bar") }
            let joinedMissing = record.missingFields.prefix(5).map(\.label).joined(separator: "、")
            let missingLabels = joinedMissing.isEmpty ? "粉重、出液量、萃取时间" : joinedMissing
            let capturedStr = capturedParts.isEmpty ? "基础录制片段" : capturedParts.joined(separator: "，")
            record.extractionDiagnosis =
                "已捕获 \(capturedStr)，但本次录制尚未完整采集到【\(missingLabels)】等实测数值。"
                + "系统不会虚构默认萃取数据，您可以在上方补全框补充实测参数后重新生成精准萃取诊断。"
            flavor = FlavorProfile(acidity: 7.2, sweetness: 7.8, body: 7.8, aroma: 8.2, aftertaste: 7.6, balance: 7.8)
            if record.flavorNotes.isEmpty {
                record.flavorNotes = ["待补全实测参数", "支持语音/手动一键补全"]
            }
            suggestions = [
                "【补充实测参数】请在上方补全「\(missingLabels)」，AI 将基于真实粉液比与流速为您计算萃取率与研磨调整建议。",
                "【当前常驻设备】默认关联 \(nonEmpty(record.grinderType) ?? "咖啡机自带磨豆机")（\(nonEmpty(record.grinderModel) ?? "格米莱 G3828A")），若本次仅介绍设备可在常驻设备库查看。",
            ]
        } else {
            // Espresso / SOE analysis with real captured parameters.
            var diagParts: [String] = []
            if (1.8...2.3).contains(ratio), (24.0...33.0).contains(timeS), (8.5...9.5).contains(pressure) {
                diagParts.append(
                    "黄金萃取区间命中！粉液比 1:\(floatStr(ratio))（\(floatStr(weight))g 粉 → \(floatStr(yieldG))g 液），耗时 \(safeInt(timeS))s，压力稳定在 \(floatStr(pressure)) bar。"
                )
                diagParts.append("油脂（Crema）呈细腻虎斑纹，前中后段流速均匀，酸甜平衡度与醇厚度表现优异。")
                flavor = FlavorProfile(acidity: 7.8, sweetness: 8.8, body: 8.5, aroma: 9.0, aftertaste: 8.6, balance: 8.9)
            } else if timeS < 22 {
                diagParts.append(
                    "流速偏快（\(safeInt(timeS))s 萃出 \(floatStr(yieldG))g，粉液比 1:\(floatStr(ratio))），存在轻微通道效应或研磨偏粗导致的萃取不足。"
                )
                flavor = FlavorProfile(acidity: 8.7, sweetness: 6.8, body: 6.5, aroma: 7.8, aftertaste: 6.4, balance: 6.9)
                suggestions.append(
                    "【研磨度调细】当前 \(nonEmpty(record.grindSetting) ?? "刻度") 流速偏快，建议将 \(nonEmpty(record.grinderModel) ?? "磨豆机") 往细调 0.5 ~ 1.0 格，把萃取时间延长至 26-30 秒。"
                )
            } else if timeS > 35 {
                diagParts.append(
                    "流速偏慢（耗时 \(safeInt(timeS))s，压力 \(floatStr(pressure)) bar），粉饼阻力较大，后段容易析出木质苦涩感。"
                )
                flavor = FlavorProfile(acidity: 6.2, sweetness: 7.2, body: 8.9, aroma: 7.9, aftertaste: 6.8, balance: 7.0)
                suggestions.append(
                    "【研磨度调粗】当前 \(nonEmpty(record.grindSetting) ?? "刻度") 阻力偏高，建议往粗微调 0.5 ~ 1 格，或将粉量减少 0.5g 至 \(floatStr(pyRound(weight - 0.5, 1)))g。"
                )
            } else {
                diagParts.append(
                    "整体萃取扎实稳定：粉重 \(floatStr(weight))g，出液 \(floatStr(yieldG))g（粉液比 1:\(floatStr(ratio))），萃取时间 \(safeInt(timeS))s，峰值压力 \(floatStr(pressure)) bar。"
                )
                flavor = FlavorProfile(acidity: 7.6, sweetness: 8.3, body: 8.2, aroma: 8.5, aftertaste: 8.1, balance: 8.3)
            }
            record.extractionDiagnosis = diagParts.joined()

            let beanName = record.beanName ?? ""
            if beanName.contains("花魁") || beanName.contains("耶加") || beanName.contains("埃塞") {
                record.flavorNotes = ["佛手柑", "热带百香果", "草莓果酱", "奶油太妃糖尾韵"]
            } else if beanName.contains("瑰夏") {
                record.flavorNotes = ["白花香气", "柠檬草", "水蜜桃", "蜂蜜红茶感"]
            } else if beanName.contains("咸芝士") {
                record.flavorNotes = ["咸芝士饼干", "曲奇黄油", "焦糖坚果", "奶油巧克力"]
            } else {
                record.flavorNotes = ["黑巧克力", "烤榛果", "焦糖甜感", "柑橘尾韵"]
            }

            if suggestions.isEmpty {
                suggestions.append(
                    "【进阶变压曲线】当前 \(floatStr(pressure)) bar 恒压表现稳定，下次可在前 6 秒采用 3 bar 低压预浸泡，尾段（22s 后）自然降压至 6 bar，进一步放大甜感并收敛尾段杂味。"
                )
            }
            suggestions.append(
                "【磨豆机与布粉优化】本次使用\(nonEmpty(record.grinderType) ?? "独立磨豆机")（\(nonEmpty(record.grinderModel) ?? "主力磨")，\(nonEmpty(record.grindSetting) ?? "标准刻度")），建议搭配 WDT 针式布粉器打散结块，保持无底手柄中心稳定出液。"
            )
            suggestions.append(
                "【饮品搭配建议】1:\(floatStr(ratio)) 的浓缩基底油脂丰厚，既适合直接品鉴 Espresso，也非常适合搭配 150ml 冰博克/明治鲜奶制作 Dirty，分口大口饮用冷热层次感拉满。"
            )
        }

        record.suggestions = suggestions
        record.flavorProfile = flavor

        // Pocket 3 / Pocket 4 Pro visual + audio timeline milestones.
        record.timelineEvents = [
            TimelineEvent(
                timestamp: "00:02",
                stage: "语音唤醒 & STA 录制启动",
                detail: "检测到唤醒词「我要开始制作咖啡」，\(record.cameraDevice) 通过局域网 STA 节点自动开启录制。"
            ),
            TimelineEvent(
                timestamp: "00:18",
                stage: "称豆 & 研磨度设定",
                detail: "语音+视觉识别：\(nonEmpty(record.beanName) ?? "精选咖啡豆")，电子秤读数 \(orDash(record.beanWeightG))g，\(nonEmpty(record.grinderType) ?? "磨豆机")（\(nonEmpty(record.grindSetting) ?? "待补充")）。"
            ),
            TimelineEvent(
                timestamp: "00:52",
                stage: "布粉压粉 & 上柄",
                detail: "相机画面捕捉到 WDT 布粉与恒力压粉动作，粉碗边缘清洁完毕。"
            ),
            TimelineEvent(
                timestamp: "01:15",
                stage: "核心萃取监测",
                detail: "方式：\(nonEmpty(record.brewMethod) ?? "意式萃取") | 压力表峰值 \(orDash(record.pressureBar)) bar | 耗时 \(orDash(record.extractionTimeS))s | 出液 \(orDash(record.yieldG))g。"
            ),
            TimelineEvent(
                timestamp: "01:48",
                stage: "自动停录 & LAN 极速回传",
                detail: "识别到结束指令/静默完成，相机自动停止录制并通过 STA 局域网 (:8088) 秒级推送 MP4 至本地 AI 引擎。"
            ),
        ]

        // Social media copy: Xiaohongshu & WeChat Moments.
        let beanDisp = nonEmpty(record.beanName) ?? "今日精选私藏豆"
        let methodDisp = nonEmpty(record.brewMethod) ?? "意式浓缩 Espresso"
        let timeDisp: String
        if isColdBrew, let t = record.extractionTimeS, t != 0 {
            timeDisp = "\(floatStr(pyRound(t / 3600, 1)))h"
        } else if let t = record.extractionTimeS {
            timeDisp = "\(safeInt(t))s"
        } else {
            timeDisp = "--s"
        }
        let notesDisp = record.flavorNotes.joined(separator: " · ")
        let roastSuffix = nonEmpty(record.beanRoast).map { "(\($0))" } ?? ""
        let firstSuggestion = record.suggestions.first ?? ""
        let secondSuggestion = record.suggestions.count > 1 ? record.suggestions[1] : ""

        let isDJISource = record.sourceType == .djiPocket || record.cameraDevice.contains("Pocket")
        let extraDeviceTag = isDJISource ? " #大疆Pocket" : " #手机拍咖啡"
        let openLine = isDJISource
            ? "今天用 \(record.cameraDevice) 记录了这杯 \(methodDisp)，从称豆到出杯一步到位，参数和风味都帮我自动整理好了 ✨"
            : "今日份居家咖啡打卡 ☕️ 随手用 \(record.cameraDevice) 拍下制作过程，端侧自动整理好了全套参数和实拍特写图组，直接来交作业 ✨"
        let tempText = record.waterTempC.map { "｜水温 \(floatStr($0))°C" } ?? ""
        let tipLines = [firstSuggestion, secondSuggestion]
            .filter { !$0.isEmpty }
            .map { "• \($0)" }
            .joined(separator: "\n")

        record.xiaohongshuCopy = """
        ☕️ \(beanDisp)｜\(orDash(record.beanWeightG))g→\(orDash(record.yieldG))g 居家萃取日记

        \(openLine)

        📋 【今日萃取档案】
        🫘 豆子：\(beanDisp) \(roastSuffix)
        ⚖️ 粉液比：\(orDash(record.beanWeightG))g 粉 ➔ \(orDash(record.yieldG))g 液（\(nonEmpty(record.brewRatio) ?? "--")）
        ⚙️ 研磨：\(nonEmpty(record.grinderModel) ?? nonEmpty(record.grinderType) ?? "常用磨豆机")｜\(nonEmpty(record.grindSetting) ?? "常规刻度")
        ⏱️ 萃取：\(methodDisp)｜\(timeDisp)｜\(orDash(record.pressureBar)) bar\(tempText)
        👅 风味：\(notesDisp)

        💡 【咖啡师复盘】
        \(tipLines)

        #居家咖啡角 #意式咖啡 #咖啡日记 #咖啡萃取记录 #家庭咖啡师 #今日份咖啡\(extraDeviceTag)
        """

        record.wechatCopy = """
        ☕️ 今日份 \(methodDisp) 出杯报告
        🫘 \(beanDisp)｜\(orDash(record.beanWeightG))g → \(orDash(record.yieldG))g (\(nonEmpty(record.brewRatio) ?? "--"))
        ⚙️ \(nonEmpty(record.grinderModel) ?? nonEmpty(record.grinderType) ?? "磨豆机") (\(nonEmpty(record.grindSetting) ?? "--"))｜⏱️ \(timeDisp) @ \(orDash(record.pressureBar)) bar
        ✨ 风味：\(notesDisp)
        """
    }

    private static func enrichEquipmentProfile(_ record: inout CoffeeRecord) {
        record.recordType = .equipmentProfile
        if record.equipmentItems.isEmpty {
            record.equipmentItems = extractEquipmentItems(from: record.transcript)
        }
        record.brewMethod = "常驻设备与器具档案补充"
        let machineName = nonEmpty(record.grinderModel) ?? "格米莱 G3828A (云象One 研磨一体咖啡机)"
        record.grinderType = nonEmpty(record.grinderType) ?? "咖啡机自带磨豆机"
        record.grinderModel = machineName
        if isNilOrEmpty(record.beanName) {
            record.beanName = "格米莱 G3828A 居家咖啡角 · 全套设备与器具档案"
        }
        record.missingFields = []
        record.status = "complete"
        record.keyframes = relabelKeyframesForEquipmentProfile(record.keyframes, items: record.equipmentItems)

        let toolNames = record.equipmentItems.map(\.name)
        record.extractionDiagnosis =
            "⚙️【常驻设备与咖啡角器具建档完成】本次录制识别为居家咖啡设备与工具盘点（未进行实际咖啡萃取，已自动归档至「个人豆仓 & 常驻设备预设」）。"
            + "主力机型为 \(machineName)，配套已收录 \(toolNames.count) 类常驻器具：\(toolNames.prefix(6).joined(separator: "、"))。"
        record.flavorNotes = [
            "格米莱 G3828A 一体机", "MHW-3BOMBER 恒力压粉", "58mm 双嘴手柄",
            "WDT 布粉破块", "丸型滤纸", "桌面吸尘清洁",
        ]
        record.suggestions = [
            "【常驻设备已自动同步】已将「格米莱 G3828A (自带豆仓 60mm 平刀研磨一体机)」及配套 58mm 压粉锤、布粉器、接粉环、双嘴手柄、丸型滤纸、桌面吸尘器写入您的常驻设备库，后续每次录制做咖啡会自动关联无需重复介绍。",
            "【咸芝士低因 SOE 冲煮建议】搭配当前豆仓中的 RARAKIDDO 咸芝士低因 SOE（中深烘，养豆期 15-20 天），建议使用双份粉碗装粉 17~19g，垫入 58mm 丸型滤纸，萃取 25~30s 出液 32~36g。",
            "【器具动线配合】接粉时套上 58mm 磁吸接粉环防飞粉 → 用 WDT 布粉针打散结块 → 四桨布粉器找平 → MHW-3BOMBER 自动回弹压粉锤垂直压实，可确保每次出品油脂绵密稳定。",
        ]
        record.timelineEvents = [
            TimelineEvent(
                timestamp: "00:05",
                stage: "主力咖啡机识别",
                detail: "语音+视觉识别：格米莱 G3828A (云象One 黑色机身，顶部自带豆仓与内置 60mm 平刀磨豆机)。"
            ),
            TimelineEvent(
                timestamp: "00:29",
                stage: "压粉与布粉器具建档",
                detail: "录入 MHW-3BOMBER 轰炸机自动回弹压粉锤、四桨布粉器、实木压粉底座与敲渣盒。"
            ),
            TimelineEvent(
                timestamp: "00:57",
                stage: "清洁与吧台配件盘点",
                detail: "录入桌面便携咖啡粉吸尘器、58mm 磁吸接粉环、WDT 针式布粉器、格米莱原装木柄压粉锤与一次性出品纸杯。"
            ),
            TimelineEvent(
                timestamp: "01:16",
                stage: "手柄与滤纸耗材归档",
                detail: "录入格米莱 58mm 实木双嘴手柄、58mm 丸型咖啡滤纸及常驻口粮豆（RARAKIDDO 咸芝士低因 SOE），已自动更新至常驻设备库。"
            ),
        ]
        let toolsBullet = record.equipmentItems
            .map { "• \($0.name)（\($0.category)）" }
            .joined(separator: "\n")
        let beanName = record.beanName ?? ""
        record.xiaohongshuCopy = """
        ☕️ 居家咖啡角设备大盘点｜用 \(record.cameraDevice) 自动建档我的咖啡制作全家福✨

        对着大疆镜头介绍了一遍家里的咖啡机和顺手小工具，AI 自动识别并同步到了我的常驻咖啡设备库，每一件都是日常出杯的好帮手！🎬

        📋 【我的常驻咖啡角装备清单】
        \(toolsBullet)
        🫘 当前在用口粮豆：\(beanName)

        💡 【吧台使用心得】
        • 格米莱 G3828A 自带豆仓一体机省空间又稳定，配合自动回弹压粉锤和 58mm 丸型滤纸，新手也能稳定压出水平粉饼、油脂超细腻！
        • 备一个桌面小吸尘器随时吸走残粉，咖啡角每天都干干净净～

        #居家咖啡角 #咖啡机推荐 #格米莱3828 #咖啡器具分享 #MHW3BOMBER #家庭咖啡馆 #大疆Pocket4Pro #咖啡日常
        """
        record.wechatCopy = """
        ☕️ 居家咖啡角常驻设备 & 器具盘点建档
        ⚙️ 主力机：\(machineName)
        🛠️ 全套器具：自动回弹压粉锤 · 布粉器 · 接粉环 · 58mm双嘴手柄 · 丸型滤纸 · 桌面吸尘器 · 出品杯
        🫘 常驻豆：\(beanName)
        📹 录制：\(record.cameraDevice) (LAN STA 自动识别建档)
        """
    }
}
