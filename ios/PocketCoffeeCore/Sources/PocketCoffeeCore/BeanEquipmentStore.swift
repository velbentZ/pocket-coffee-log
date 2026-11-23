import CryptoKit
import Foundation

public enum BeanScanMergeMode: String, CaseIterable, Identifiable, Sendable {
    case supplementCurrent = "补全当前袋"
    case restockNewBag = "复购新袋累加"
    case createSeparate = "另存为新豆"

    public var id: String { rawValue }
}

public struct BeanBagScanResult: Equatable, Sendable {
    public let ocrText: String
    public let scannedBean: BeanEntry
    public let matchedExistingBean: BeanEntry?

    public init(ocrText: String, scannedBean: BeanEntry, matchedExistingBean: BeanEntry?) {
        self.ocrText = ocrText
        self.scannedBean = scannedBean
        self.matchedExistingBean = matchedExistingBean
    }
}

/// Swift port of `core/bean_equipment_store.py` (`BeanAndEquipmentManager`):
/// personal coffee bean inventory with spoken shorthand aliases, coffee-bag label
/// parsing (OCR or natural language), automatic dose deduction, and the permanent
/// equipment profile (espresso machine, default grinders, bar accessories).
/// Persists to `bean_equipment_library.json` inside the given directory.
public final class BeanEquipmentStore: @unchecked Sendable {

    public static let seededSampleBeanIDs: Set<String> = [
        "bean-huakui",
        "bean-geisha",
        "bean-paraiso",
    ]

    private let directoryURL: URL
    private let fileURL: URL
    private let lock = NSLock()

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.fileURL = directoryURL.appendingPathComponent("bean_equipment_library.json")
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            writeLibraryLocked(makeSeededLibrary())
        }
    }

    // MARK: - Persistence

    public func loadLibrary() -> BeanEquipmentLibrary {
        lock.lock()
        defer { lock.unlock() }
        return loadLibraryLocked()
    }

    public func saveLibrary(_ library: BeanEquipmentLibrary) {
        lock.lock()
        defer { lock.unlock() }
        var normalized = library
        normalized.beans = library.beans.map(normalizeBean)
        writeLibraryLocked(normalized)
    }

    private func loadLibraryLocked() -> BeanEquipmentLibrary {
        if let data = try? Data(contentsOf: fileURL),
           var library = try? JSONDecoder().decode(BeanEquipmentLibrary.self, from: data) {
            library.beans = library.beans.map(normalizeBean)
            library.equipment.machinePhotoPath = SandboxPathResolver.resolveLocalFilePath(
                library.equipment.machinePhotoPath,
                additionalAllowedRoots: [directoryURL]
            )
            return library
        }
        let seeded = makeSeededLibrary()
        writeLibraryLocked(seeded)
        return seeded
    }

    private func writeLibraryLocked(_ library: BeanEquipmentLibrary) {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directoryURL.path
        )
        #endif
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(library) {
            #if os(iOS)
            let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            #else
            let options: Data.WritingOptions = [.atomic]
            #endif
            try? data.write(to: fileURL, options: options)
        }
    }

    private func makeSeededLibrary() -> BeanEquipmentLibrary {
        let beans = [
            BeanEntry(
                id: "bean-huakui",
                shortAliases: ["花魁", "花魁7.0", "罕贝拉"],
                fullName: "埃塞俄比亚 罕贝拉 花魁 7.0 日晒",
                roastLevel: "中浅烘焙",
                roastDate: "2026-11-05",
                initialWeightG: 250,
                remainingWeightG: 185,
                recommendedGrind: "刻度 14.5 格",
                flavorTags: ["佛手柑", "热带百香果", "草莓果酱", "奶油太妃糖"],
                goldenRecipeNote: "Niche 刻度 14.5 | 18.5g -> 37g | 29s @ 9.2 bar",
                shotsCount: 3
            ),
            BeanEntry(
                id: "bean-geisha",
                shortAliases: ["瑰夏", "绿标瑰夏", "红标瑰夏", "翡翠庄园"],
                fullName: "巴拿马 翡翠庄园 绿标瑰夏 水洗",
                roastLevel: "浅度烘焙",
                roastDate: "2026-11-15",
                initialWeightG: 200,
                remainingWeightG: 140,
                recommendedGrind: "刻度 13.5 格 (意式) / 刻度 58 格 (冷萃)",
                flavorTags: ["茉莉白花", "佛手柑", "水蜜桃汁", "蜂蜜红茶尾韵"],
                goldenRecipeNote: "意式 93°C 18g->40g 27s | 冷萃 45g->405ml 12h",
                shotsCount: 3
            ),
            BeanEntry(
                id: "bean-paraiso",
                shortAliases: ["天堂庄园", "哥伦比亚", "双重厌氧"],
                fullName: "哥伦比亚 考卡山谷 天堂庄园 双重厌氧水洗",
                roastLevel: "中浅烘焙",
                roastDate: "2026-10-16",
                initialWeightG: 250,
                remainingWeightG: 210,
                recommendedGrind: "刻度 14.0 格",
                flavorTags: ["水蜜桃酸奶", "玫瑰花露", "白桃乌龙", "丝滑奶油"],
                goldenRecipeNote: "搭配冰博克制作 Dirty 绝佳，刻度 14.0 流速最稳",
                shotsCount: 2
            ),
        ]
        return BeanEquipmentLibrary(beans: beans.map(normalizeBean), equipment: EquipmentProfile())
    }

    /// Mirrors `_normalize_bean_dict`: clean full name, ISO roast date (fallback:
    /// 10 days ago), clamped/rounded weights, non-negative shot count, and strictly
    /// sandbox-validated photo paths (dropping any invalid/traversal paths).
    private func normalizeBean(_ bean: BeanEntry) -> BeanEntry {
        var b = bean
        let cleanID = bean.id
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        b.id = cleanID.isEmpty ? "bean-\(Self.timeStampHHmmss())" : String(cleanID.prefix(64))
        let trimmedName = String(bean.fullName.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
        b.fullName = trimmedName.isEmpty ? "未命名咖啡豆" : trimmedName
        b.shortAliases = Array(
            bean.shortAliases
                .map { String($0.prefix(64)).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(12)
        )
        b.flavorTags = Array(
            bean.flavorTags
                .map { String($0.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(16)
        )
        let fallbackDate = Calendar.current.date(byAdding: .day, value: -10, to: Date()) ?? Date()
        b.roastDate = Self.normalizeDateStr(bean.roastDate) ?? Self.isoDateString(from: fallbackDate)
        b.expiryDate = Self.normalizeDateStr(bean.expiryDate) ?? ""
        let safeRem = bean.remainingWeightG.isFinite ? min(max(0.0, bean.remainingWeightG), 100_000.0) : 0.0
        let safeInit = bean.initialWeightG.isFinite ? min(max(0.0, bean.initialWeightG), 100_000.0) : 250.0
        b.remainingWeightG = Self.round2(safeRem)
        b.initialWeightG = Self.round2(safeInit)
        b.shotsCount = max(0, min(bean.shotsCount, 1_000_000))
        b.coverImagePath = SandboxPathResolver.resolveLocalFilePath(
            bean.coverImagePath,
            additionalAllowedRoots: [directoryURL]
        )
        var resolvedPhotos: [String] = []
        for p in bean.photoPaths.prefix(16) {
            if let validPath = SandboxPathResolver.resolveLocalFilePath(p, additionalAllowedRoots: [directoryURL]),
               !resolvedPhotos.contains(validPath) {
                resolvedPhotos.append(validPath)
            }
        }
        if let cover = b.coverImagePath, !cover.isEmpty, !resolvedPhotos.contains(cover) {
            resolvedPhotos.insert(cover, at: 0)
        }
        if b.coverImagePath == nil, let firstValid = resolvedPhotos.first {
            b.coverImagePath = firstValid
        }
        b.photoPaths = Array(resolvedPhotos.prefix(16))
        return b
    }

    // MARK: - Shorthand matching

    /// Matches spoken shorthand (e.g. 「今天用花魁」 or 「冲一杯瑰夏」) against the bean
    /// library so the user doesn't have to recite origin/process/roast every time.
    public func matchBean(in text: String) -> BeanEntry? {
        lock.lock()
        defer { lock.unlock() }
        let beans = loadLibraryLocked().beans
        guard let idx = Self.findBeanIndex(in: beans, query: text) else { return nil }
        return beans[idx]
    }

    private static func findBeanIndex(in beans: [BeanEntry], query: String) -> Int? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return nil }
        // 1. Exact id / full name / alias match.
        for (idx, bean) in beans.enumerated() {
            if bean.id.lowercased() == q { return idx }
            if bean.fullName.lowercased() == q { return idx }
            if bean.shortAliases.contains(where: { !$0.isEmpty && $0.lowercased() == q }) { return idx }
        }
        // 2. Substring alias or full-name match.
        for (idx, bean) in beans.enumerated() {
            for alias in bean.shortAliases where !alias.isEmpty && q.contains(alias.lowercased()) {
                return idx
            }
            let fullName = bean.fullName.lowercased()
            if !fullName.isEmpty && (q.contains(fullName) || fullName.contains(q)) { return idx }
        }
        return nil
    }

    // MARK: - Bean CRUD & dose deduction

    public func addOrUpdateBean(_ bean: BeanEntry) -> BeanEntry {
        lock.lock()
        defer { lock.unlock() }
        var library = loadLibraryLocked()
        var incoming = bean
        if incoming.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            incoming.id = "bean-\(Self.timeStampHHmmss())"
        }
        let normalized = normalizeBean(incoming)
        if let idx = library.beans.firstIndex(where: { $0.id == normalized.id }) {
            library.beans[idx] = normalized
        } else {
            library.beans.insert(normalized, at: 0)
        }
        writeLibraryLocked(library)
        return normalized
    }

    /// Deducts `doseG` from the matched bean's remaining weight (clamped at 0),
    /// increments the shot count, and persists the updated library.
    public func deductBeanDose(beanName: String, doseG: Double) -> BeanEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard !beanName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard doseG.isFinite else { return nil }
        let dose = max(0.0, doseG)
        var library = loadLibraryLocked()
        guard let idx = Self.findBeanIndex(in: library.beans, query: beanName) else { return nil }
        var bean = library.beans[idx]
        bean.remainingWeightG = Self.round2(max(0.0, bean.remainingWeightG - dose))
        bean.shotsCount += 1
        let normalized = normalizeBean(bean)
        library.beans[idx] = normalized
        writeLibraryLocked(library)
        return normalized
    }

    public func deleteBean(id: String) {
        _ = deleteBeans(ids: [id])
    }

    @discardableResult
    public func deleteBeans(ids: Set<String>) -> Int {
        guard !ids.isEmpty else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        var library = loadLibraryLocked()
        let before = library.beans.count
        library.beans.removeAll { ids.contains($0.id) }
        let removed = before - library.beans.count
        if removed > 0 {
            writeLibraryLocked(library)
        }
        return removed
    }

    @discardableResult
    public func removeSeededSampleBeans() -> Int {
        lock.lock()
        defer { lock.unlock() }
        var library = loadLibraryLocked()
        let before = library.beans.count
        library.beans.removeAll { Self.seededSampleBeanIDs.contains($0.id) }
        let removed = before - library.beans.count
        if removed > 0 {
            writeLibraryLocked(library)
        }
        return removed
    }

    /// Automatically creates or updates a bean entry in the library whenever a real brew
    /// report recognizes a coffee bean (and attaches the coffee-bean / scale close-up frame).
    @discardableResult
    public func upsertBeanFromBrewRecord(_ record: CoffeeRecord) -> BeanEntry? {
        guard record.recordType != .equipmentProfile else { return nil }
        guard let rawName = record.beanName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty else {
            return nil
        }

        let ignoredPlaceholders: Set<String> = [
            "今日精选咖啡", "未命名咖啡豆", "咖啡制作记录", "未知咖啡豆",
        ]
        if ignoredPlaceholders.contains(rawName) { return nil }

        let coverPath = Self.selectBeanCoverImagePath(from: record)
        let recipeNote = Self.buildRecipeSummary(from: record)
        let dose: Double = {
            guard let raw = record.beanWeightG, raw.isFinite, raw > 0 else { return 0.0 }
            return min(raw, 100_000.0)
        }()

        lock.lock()
        defer { lock.unlock() }
        var library = loadLibraryLocked()

        if let idx = Self.findBeanIndex(in: library.beans, query: rawName) {
            var existing = library.beans[idx]
            if dose > 0 {
                existing.remainingWeightG = Self.round2(max(0.0, existing.remainingWeightG - dose))
            }
            existing.shotsCount += 1
            if (existing.coverImagePath ?? "").isEmpty, let coverPath {
                existing.coverImagePath = coverPath
            }
            if existing.recommendedGrind.isEmpty, let grind = record.grindSetting, !grind.isEmpty {
                existing.recommendedGrind = grind
            }
            if existing.flavorTags.isEmpty && !record.flavorNotes.isEmpty {
                existing.flavorTags = Array(record.flavorNotes.prefix(4))
            }
            if !recipeNote.isEmpty && existing.goldenRecipeNote.isEmpty {
                existing.goldenRecipeNote = recipeNote
            }
            let normalized = normalizeBean(existing)
            library.beans[idx] = normalized
            writeLibraryLocked(library)
            return normalized
        }

        var aliases: [String] = [rawName]
        if rawName.count >= 4 {
            let trimmedSuffix = rawName
                .replacingOccurrences(of: "咖啡豆", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSuffix.isEmpty && !aliases.contains(trimmedSuffix) {
                aliases.append(trimmedSuffix)
            }
        }

        let initialWeight: Double = 250.0
        let remaining = Self.round2(max(0.0, initialWeight - dose))
        let roastDate = String(record.createdAt.prefix(10))

        let resolvedRoast = (record.beanRoast?.isEmpty == false) ? (record.beanRoast ?? "中度烘焙") : "中度烘焙"
        let created = BeanEntry(
            id: "bean-\(Self.shortSHA1(rawName))",
            shortAliases: aliases,
            fullName: rawName,
            roastLevel: resolvedRoast,
            roastDate: roastDate,
            initialWeightG: initialWeight,
            remainingWeightG: remaining,
            recommendedGrind: record.grindSetting ?? "",
            flavorTags: Array(record.flavorNotes.prefix(4)),
            goldenRecipeNote: recipeNote,
            shotsCount: 1,
            coverImagePath: coverPath
        )

        let normalized = normalizeBean(created)
        library.beans.insert(normalized, at: 0)
        writeLibraryLocked(library)
        return normalized
    }

    /// Backfills any real user brew records whose recognized bean is not yet in the bean library.
    @discardableResult
    public func backfillBeansFromRecords(_ records: [CoffeeRecord]) -> Int {
        let sampleRecordPrefixes = ["brew-20261115-", "brew-20261114-"]
        var added = 0
        for record in records where record.recordType == .brewReport {
            if sampleRecordPrefixes.contains(where: { record.id.hasPrefix($0) }) { continue }
            guard let name = record.beanName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            if matchBean(in: name) == nil {
                if upsertBeanFromBrewRecord(record) != nil {
                    added += 1
                }
            } else if let existing = matchBean(in: name),
                      (existing.coverImagePath ?? "").isEmpty,
                      let coverPath = Self.selectBeanCoverImagePath(from: record) {
                var updated = existing
                updated.coverImagePath = coverPath
                _ = addOrUpdateBean(updated)
            }
        }
        return added
    }

    /// Backfills explicitly mentioned coffee accessories from existing real user brew reports
    /// into the permanent equipment profile without overwriting user-configured defaults.
    @discardableResult
    public func backfillEquipmentFromRecords(_ records: [CoffeeRecord]) -> Int {
        let sampleRecordPrefixes = ["brew-20261115-", "brew-20261114-"]
        var collected: [EquipmentItem] = []
        var seenIDs = Set<String>()
        for record in records where record.recordType == .brewReport {
            if sampleRecordPrefixes.contains(where: { record.id.hasPrefix($0) }) { continue }
            let mentioned = ChineseCoffeeAnalyzer.extractMentionedEquipmentItems(from: record.transcript)
            for item in mentioned where seenIDs.insert(item.id).inserted {
                collected.append(item)
            }
        }
        guard !collected.isEmpty else { return 0 }
        let beforeCount = loadLibrary().equipment.accessories.count
        let updated = updateEquipmentFromIntro(equipmentItems: collected)
        return max(0, updated.accessories.count - beforeCount)
    }

    private static func selectBeanCoverImagePath(from record: CoffeeRecord) -> String? {
        let valid = SandboxPathResolver.exportableXiaohongshuKeyframes(for: record)
        guard !valid.isEmpty else { return nil }
        if let bag = valid.first(where: { $0.stageKey == "bean_bag" }) {
            return bag.imagePath
        }
        if let scale = valid.first(where: { $0.stageKey == "scale_dose" }) {
            return scale.imagePath
        }
        return valid.first?.imagePath
    }

    private static func buildRecipeSummary(from record: CoffeeRecord) -> String {
        var parts: [String] = []
        if let grinder = record.grinderModel, !grinder.isEmpty {
            parts.append(grinder)
        }
        if let grind = record.grindSetting, !grind.isEmpty {
            parts.append(grind)
        }
        if let w = record.beanWeightG, w.isFinite, let y = record.yieldG, y.isFinite {
            let ratio = record.brewRatio.map { " (\($0))" } ?? ""
            parts.append(String(format: "%.1fg -> %.1fg%@", w, y, ratio))
        } else if let w = record.beanWeightG, w.isFinite {
            parts.append(String(format: "粉量 %.1fg", w))
        }
        if let t = record.extractionTimeS, t.isFinite, t >= 0 {
            let clamped = Int(min(t, 100_000.0))
            parts.append("\(clamped)s")
        }
        return parts.joined(separator: " | ")
    }

    private static func shortSHA1(_ text: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(text.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Equipment profile

    /// Merges recognized machine/grinder/bar accessories into the permanent equipment
    /// profile. Accessories are merged by `id` (fallback: name) without duplicates.
    public func updateEquipmentFromIntro(
        equipmentItems: [EquipmentItem],
        grinderType: String? = nil,
        grinderModel: String? = nil,
        espressoMachine: String? = nil
    ) -> EquipmentProfile {
        lock.lock()
        defer { lock.unlock() }
        var library = loadLibraryLocked()
        var profile = library.equipment
        if let grinderType, !grinderType.isEmpty { profile.defaultGrinderType = grinderType }
        if let grinderModel, !grinderModel.isEmpty { profile.defaultGrinderModel = grinderModel }
        if let espressoMachine, !espressoMachine.isEmpty { profile.espressoMachine = espressoMachine }

        var order: [String] = []
        var byID: [String: EquipmentItem] = [:]
        for item in profile.accessories {
            let key = item.id.isEmpty ? item.name : item.id
            if byID[key] == nil { order.append(key) }
            byID[key] = item
        }
        for (idx, item) in equipmentItems.enumerated() {
            let key: String
            if !item.id.isEmpty {
                key = item.id
            } else if !item.name.isEmpty {
                key = item.name
            } else {
                key = "eq-\(idx)"
            }
            if var existing = byID[key] {
                // Incoming non-empty fields win; empty fields keep the stored value
                // (mirrors Python's `{**existing, **incoming}` dict merge).
                if !item.id.isEmpty { existing.id = item.id }
                if !item.name.isEmpty { existing.name = item.name }
                if !item.category.isEmpty { existing.category = item.category }
                if !item.spec.isEmpty { existing.spec = item.spec }
                if !item.role.isEmpty { existing.role = item.role }
                byID[key] = existing
            } else {
                order.append(key)
                byID[key] = item
            }
        }
        profile.accessories = order.compactMap { byID[$0] }
        library.equipment = profile
        writeLibraryLocked(library)
        return profile
    }

    public func saveEquipmentProfile(_ profile: EquipmentProfile) -> EquipmentProfile {
        lock.lock()
        defer { lock.unlock() }
        var library = loadLibraryLocked()
        var sanitized = profile
        sanitized.defaultGrinderType = String(profile.defaultGrinderType.prefix(200))
        sanitized.defaultGrinderModel = String(profile.defaultGrinderModel.prefix(200))
        sanitized.secondaryGrinderModel = String(profile.secondaryGrinderModel.prefix(200))
        sanitized.espressoMachine = String(profile.espressoMachine.prefix(200))
        if !profile.defaultWaterTempC.isFinite || profile.defaultWaterTempC < 0 || profile.defaultWaterTempC > 110 {
            sanitized.defaultWaterTempC = 93.0
        }
        sanitized.accessories = Array(profile.accessories.prefix(64))
        sanitized.machinePhotoPath = SandboxPathResolver.resolveLocalFilePath(
            profile.machinePhotoPath,
            additionalAllowedRoots: [directoryURL]
        )
        library.equipment = sanitized
        writeLibraryLocked(library)
        return sanitized
    }

    // MARK: - Coffee bag label parsing

    /// Extracts structured bean-card fields from natural language or OCR text on a
    /// coffee bag (Brewlog / Filtru AI bag-scanner style) and saves/updates the bean.
    public func parseBeanLabelText(_ text: String, coverImagePath: String? = nil, photoPaths: [String] = []) -> BeanEntry {
        let preview = parseBeanLabelPreview(text, coverImagePath: coverImagePath, photoPaths: photoPaths)
        return addOrUpdateBean(preview)
    }

    /// Non-mutating parser for OCR / bag label text so the UI can show a pre-filled editor
    /// for confirmation before persisting to the bean library.
    public func parseBeanLabelPreview(_ text: String, coverImagePath: String? = nil, photoPaths: [String] = []) -> BeanEntry {
        let raw = String(text.prefix(10_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveCover = coverImagePath ?? photoPaths.first
        if raw.isEmpty {
            return normalizeBean(BeanEntry(
                id: "bean-scan-\(Self.timeStampHHmmss())",
                shortAliases: ["未命名豆袋"],
                fullName: "未命名豆袋",
                roastLevel: "中浅烘焙",
                roastDate: Self.isoDateString(from: Date()),
                expiryDate: "",
                initialWeightG: 250,
                remainingWeightG: 250,
                recommendedGrind: "刻度 14.0 格",
                flavorTags: ["柑橘", "坚果"],
                goldenRecipeNote: "AI 豆袋标签自动建档",
                shotsCount: 0,
                coverImagePath: effectiveCover,
                photoPaths: photoPaths
            ))
        }

        // 1. Roast/production date & expiry/best-before date.
        let (roastDate, expiryDate) = Self.extractRoastAndExpiryDates(from: raw)

        // 2. Bag weight (initial & optional remaining).
        var weightMatches: [Double] = []
        if let regex = try? NSRegularExpression(pattern: #"(?<![0-9.])(\d{1,6}(?:\.\d{1,2})?)\s*(?:g|G|克|grams?)(?![a-zA-Z0-9])"#) {
            let ns = raw as NSString
            for match in regex.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
                if let value = Double(ns.substring(with: match.range(at: 1))) {
                    weightMatches.append(value)
                }
            }
        }
        let bagWeights = weightMatches.filter { $0 >= 30.0 }
        let initialWeight = bagWeights.first ?? weightMatches.first ?? 250.0
        var remainingWeight = initialWeight
        if let rem = Self.firstCapture(#"(?:剩余|余量)\s*(?<![0-9.])(\d{1,6}(?:\.\d{1,2})?)\s*(?:g|G|克)"#, in: raw),
           let value = Double(rem) {
            remainingWeight = value
        }

        // 3. Origin.
        let lowered = raw.lowercased()
        var origin = Self.firstCapture(#"产地\s*[:：]\s*([^\s,，;；\n]+)"#, in: raw)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if origin.isEmpty {
            for rule in Self.originRules where rule.keywords.contains(where: { lowered.contains($0.lowercased()) }) {
                origin = rule.label
                break
            }
        }
        if origin.isEmpty { origin = "精品单品产区" }

        // 4. Process.
        var process = ""
        for rule in Self.processRules where rule.keywords.contains(where: { lowered.contains($0.lowercased()) }) {
            process = rule.label
            break
        }
        if process.isEmpty { process = "水洗 (Washed)" }

        // 5. Roast level.
        var roastLevel = ""
        for rule in Self.roastRules where rule.keywords.contains(where: { lowered.contains($0.lowercased()) }) {
            roastLevel = rule.label
            break
        }
        if roastLevel.isEmpty { roastLevel = "中浅烘焙" }

        // 6. Flavor tags (contiguous Chinese notes and delimited lists).
        let lexicon = Self.flavorLexicon.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.count != rhs.element.count { return lhs.element.count > rhs.element.count }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        var foundFlavors: [(pos: Int, note: String)] = []
        var masked = raw as NSString
        for note in lexicon {
            let range = masked.range(of: note)
            if range.location != NSNotFound {
                foundFlavors.append((range.location, note))
                masked = masked.replacingCharacters(
                    in: range,
                    with: String(repeating: " ", count: note.count)
                ) as NSString
            }
        }
        var flavorTags = foundFlavors.sorted { $0.pos < $1.pos }.map(\.note)
        if let explicit = Self.firstCapture(#"风味(?:描述|标签)?\s*[:：]\s*([^\n;；]+)"#, in: raw) {
            let tokens = Self.splitByRegex(#"[,，、/·\s]+"#, text: explicit.trimmingCharacters(in: .whitespacesAndNewlines))
            for token in tokens {
                let tok = token.trimmingCharacters(in: .whitespacesAndNewlines)
                if tok.isEmpty { continue }
                if Self.containsMatch(#"烘焙|日期|\d+g|\d+克"#, in: tok) { continue }
                if flavorTags.contains(tok) { continue }
                flavorTags.append(tok)
            }
        }
        if flavorTags.isEmpty { flavorTags = ["柑橘", "花香", "焦糖甜感"] }

        // 7. Clean bean name & full name (bounded whitespace quantifiers to prevent ReDoS).
        var cleaned = raw
        cleaned = Self.replaceMatches(#"(?:生产|烘焙|出厂|到期|保质期至?|赏味期至?|有效期至?)(?:日期|时间)?\s{0,8}(?:[:：]\s{0,8})?20\d{2}\s{0,4}[-/.年]\s{0,4}\d{1,2}\s{0,4}[-/.月]\s{0,4}\d{1,2}日?"#, in: cleaned, with: " ")
        cleaned = Self.replaceMatches(#"(?:保质期|赏味期|有效期)\s{0,8}(?:[:：]\s{0,8})?\d{1,4}\s{0,4}(?:个月|月|天|日|年)"#, in: cleaned, with: " ")
        cleaned = Self.replaceMatches(#"20\d{2}\s{0,4}[-/.年]\s{0,4}\d{1,2}\s{0,4}[-/.月]\s{0,4}\d{1,2}日?"#, in: cleaned, with: " ")
        cleaned = Self.replaceMatches(#"(?:(?:净含量|豆重|克重|剩余|余量)\s{0,6})?(?<![0-9.])\d{1,6}(?:\.\d{1,2})?\s{0,6}(?:g|G|克|grams?)(?![a-zA-Z0-9])"#, in: cleaned, with: " ")
        cleaned = Self.replaceMatches(#"(?:风味(?:描述|标签)?|产地|处理法|烘焙度?)\s{0,8}[:：]\s{0,8}[^\s,，;；\n]+"#, in: cleaned, with: " ")
        for note in lexicon {
            cleaned = cleaned.replacingOccurrences(of: note, with: " ")
        }
        for rule in Self.roastRules {
            for keyword in rule.keywords {
                cleaned = Self.replaceMatches(NSRegularExpression.escapedPattern(for: keyword), in: cleaned, with: " ")
            }
        }
        let processShort = process.components(separatedBy: " ")[0]
        for rule in Self.processRules {
            for keyword in rule.keywords {
                cleaned = Self.replaceMatches(NSRegularExpression.escapedPattern(for: keyword), in: cleaned, with: " ")
            }
        }

        let stripSet = CharacterSet(charactersIn: "·-—_/,，、:：()（）")
        var tokens = Self.splitByRegex(#"[\s,，;；|]+"#, text: cleaned)
            .map { $0.trimmingCharacters(in: stripSet) }
            .filter { !$0.isEmpty }
        tokens = tokens.filter {
            !["烘焙日期", "生产日期", "到期日期", "保质期", "赏味期", "烘焙", "净含量", "风味", "咖啡豆"].contains($0)
        }

        var baseName = tokens.prefix(3).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if baseName.isEmpty {
            let originPrefix = origin.components(separatedBy: "·")[0].trimmingCharacters(in: .whitespacesAndNewlines)
            baseName = "\(originPrefix) \(processShort)".trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let name = baseName
        let fullName = baseName.contains(processShort)
            ? baseName
            : "\(baseName) \(processShort)".trimmingCharacters(in: .whitespacesAndNewlines)

        // 8. Spoken short aliases.
        var aliases: [String] = []
        for candidate in Self.varietalOrEstateAliases
        where lowered.contains(candidate.lowercased()) && !aliases.contains(candidate) {
            aliases.append(candidate)
        }
        if !aliases.contains(name) { aliases.insert(name, at: 0) }
        if let last = tokens.last, last.count >= 2, !aliases.contains(last) {
            aliases.append(last)
        }

        // Recommended grind & ratio heuristics based on roast level.
        let recGrind: String
        let recRatio: String
        if roastLevel.contains("浅") && !roastLevel.contains("中") {
            recGrind = "刻度 13.5 格"
            recRatio = "1:2.2"
        } else if roastLevel.contains("深") {
            recGrind = "刻度 15.0 格"
            recRatio = "1:1.8"
        } else {
            recGrind = "刻度 14.2 格"
            recRatio = "1:2.0"
        }

        let digest = Insecure.SHA1.hash(data: Data(fullName.lowercased().utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        var beanID = "bean-\(hex.prefix(8))"
        // Reuse the existing bean id when the exact full name already exists.
        let existingBeans = loadLibrary().beans
        if let existing = existingBeans.first(where: {
            $0.fullName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == fullName.lowercased()
        }) {
            beanID = existing.id
        }

        let beanCard = BeanEntry(
            id: beanID,
            shortAliases: Array(aliases.prefix(6)),
            fullName: fullName,
            roastLevel: roastLevel,
            roastDate: roastDate,
            expiryDate: expiryDate,
            initialWeightG: Self.round2(initialWeight),
            remainingWeightG: Self.round2(remainingWeight),
            recommendedGrind: recGrind,
            flavorTags: Array(flavorTags.prefix(8)),
            goldenRecipeNote: "AI 豆袋扫描入库 · 建议 \(recGrind) / 18g 粉 (\(recRatio))",
            shotsCount: 0,
            coverImagePath: effectiveCover,
            photoPaths: photoPaths
        )
        return normalizeBean(beanCard)
    }

    private static func extractRoastAndExpiryDates(from raw: String) -> (roast: String, expiry: String) {
        let dateCore = #"(20\d{2}\s{0,4}[-/.年]\s{0,4}\d{1,2}\s{0,4}[-/.月]\s{0,4}\d{1,2}日?)"#

        var roast: String?
        if let explicitRoast = firstCapture(#"(?:生产|烘焙|出厂|ROAST(?:ED)?)(?:日期|时间|DATE)?\s{0,8}(?:[:：]\s{0,8})?"# + dateCore, in: raw) {
            roast = normalizeDateStr(explicitRoast)
        }

        var expiry: String?
        if let explicitExpiry = firstCapture(#"(?:到期|保质期至?|赏味期至?|有效期至?|最佳赏味|EXP(?:IRY)?|BEST\s{0,4}BEFORE)(?:日期|时间|DATE)?\s{0,8}(?:[:：]\s{0,8})?"# + dateCore, in: raw) {
            expiry = normalizeDateStr(explicitExpiry)
        }

        var allDates: [String] = []
        if let regex = try? NSRegularExpression(pattern: dateCore) {
            let ns = raw as NSString
            for match in regex.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
                let sub = ns.substring(with: match.range(at: 1))
                if let iso = normalizeDateStr(sub), !allDates.contains(iso) {
                    allDates.append(iso)
                }
            }
        }
        allDates.sort()

        if roast == nil {
            roast = allDates.first ?? isoDateString(from: Date())
        }
        if expiry == nil, let r = roast, allDates.count >= 2, let later = allDates.last, later > r {
            expiry = later
        }

        if expiry == nil, let r = roast, let roastDateObj = BeanEntry.parseISODate(r) {
            if let monthsStr = firstCapture(#"(?:保质期|赏味期|有效期)\s{0,8}(?:[:：]\s{0,8})?(\d{1,2})\s{0,4}个?月"#, in: raw),
               let months = Int(monthsStr), months > 0,
               let computed = Calendar.current.date(byAdding: .month, value: months, to: roastDateObj) {
                expiry = isoDateString(from: computed)
            } else if let daysStr = firstCapture(#"(?:保质期|赏味期|有效期)\s{0,8}(?:[:：]\s{0,8})?(\d{1,3})\s{0,4}[天日]"#, in: raw),
                      let days = Int(daysStr), days > 0,
                      let computed = Calendar.current.date(byAdding: .day, value: days, to: roastDateObj) {
                expiry = isoDateString(from: computed)
            } else if let yearsStr = firstCapture(#"(?:保质期|赏味期|有效期)\s{0,8}(?:[:：]\s{0,8})?(\d{1})\s{0,4}年"#, in: raw),
                      let years = Int(yearsStr), years > 0,
                      let computed = Calendar.current.date(byAdding: .year, value: years, to: roastDateObj) {
                expiry = isoDateString(from: computed)
            }
        }

        return (roast ?? isoDateString(from: Date()), expiry ?? "")
    }

    /// Finds an existing bean in the library that matches either the parsed bean name,
    /// its aliases, or the raw OCR bag text (handles partial / alias matches like
    /// existing "咸芝士低因" vs scanned "咸芝士低因 意式拼配 水洗").
    public func findMatchingBeanForScan(rawText: String, parsedBean: BeanEntry) -> BeanEntry? {
        if let hit = matchBean(in: parsedBean.fullName) {
            return hit
        }
        for alias in parsedBean.shortAliases where !alias.isEmpty {
            if let hit = matchBean(in: alias) {
                return hit
            }
        }
        if !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let hit = matchBean(in: rawText) {
            return hit
        }
        return nil
    }

    /// Combines a newly scanned bean card with an already-stored bean according to the
    /// user-chosen merge mode:
    /// - `.supplementCurrent`: keeps existing weight & shot count, updates photo/dates/flavors.
    /// - `.restockNewBag`: keeps shot count, adds new bag weight to remaining weight, updates dates/photo.
    /// - `.createSeparate`: creates a distinct new bean entry with a fresh unique ID.
    public static func mergeScannedBean(
        _ scanned: BeanEntry,
        with existing: BeanEntry,
        mode: BeanScanMergeMode
    ) -> BeanEntry {
        switch mode {
        case .supplementCurrent:
            var merged = existing
            if let newCover = scanned.coverImagePath, !newCover.isEmpty {
                merged.coverImagePath = newCover
            }
            var mergedPhotos = existing.allPhotoPaths
            for p in scanned.allPhotoPaths where !mergedPhotos.contains(p) {
                mergedPhotos.append(p)
            }
            merged.photoPaths = mergedPhotos
            if !scanned.roastDate.isEmpty {
                merged.roastDate = scanned.roastDate
            }
            if !scanned.expiryDate.isEmpty {
                merged.expiryDate = scanned.expiryDate
            }
            if !scanned.roastLevel.isEmpty {
                merged.roastLevel = scanned.roastLevel
            }
            if !scanned.flavorTags.isEmpty {
                var tags = existing.flavorTags
                for t in scanned.flavorTags where !tags.contains(t) {
                    tags.append(t)
                }
                merged.flavorTags = Array(tags.prefix(8))
            }
            if !scanned.shortAliases.isEmpty {
                var aliases = existing.shortAliases
                for a in scanned.shortAliases where !a.isEmpty && !aliases.contains(a) {
                    aliases.append(a)
                }
                merged.shortAliases = Array(aliases.prefix(8))
            }
            if merged.recommendedGrind.isEmpty && !scanned.recommendedGrind.isEmpty {
                merged.recommendedGrind = scanned.recommendedGrind
            }
            return merged

        case .restockNewBag:
            var merged = existing
            let addedBag = max(0.0, scanned.initialWeightG)
            let newRemaining = round2(existing.remainingWeightG + addedBag)
            merged.remainingWeightG = newRemaining
            merged.initialWeightG = round2(max(existing.initialWeightG, newRemaining))
            if let newCover = scanned.coverImagePath, !newCover.isEmpty {
                merged.coverImagePath = newCover
            }
            var mergedPhotos = scanned.allPhotoPaths
            for p in existing.allPhotoPaths where !mergedPhotos.contains(p) {
                mergedPhotos.append(p)
            }
            merged.photoPaths = mergedPhotos
            if !scanned.roastDate.isEmpty {
                merged.roastDate = scanned.roastDate
            }
            if !scanned.expiryDate.isEmpty {
                merged.expiryDate = scanned.expiryDate
            }
            if !scanned.roastLevel.isEmpty {
                merged.roastLevel = scanned.roastLevel
            }
            return merged

        case .createSeparate:
            var separate = scanned
            separate.id = "bean-\(shortSHA1("\(scanned.fullName)-\(UUID().uuidString)"))"
            return separate
        }
    }

    // MARK: - Label rule tables (ported from core/bean_equipment_store.py)

    private static let originRules: [(keywords: [String], label: String)] = [
        (["巴拿马", "翡翠庄园", "Panama", "Esmeralda"], "巴拿马 · 波奎特/翡翠庄园"),
        (["罕贝拉", "Hambela"], "埃塞俄比亚 · 古吉罕贝拉"),
        (["耶加雪菲", "Yirgacheffe"], "埃塞俄比亚 · 耶加雪菲"),
        (["西达摩", "Sidamo"], "埃塞俄比亚 · 西达摩"),
        (["埃塞俄比亚", "埃塞", "Ethiopia"], "埃塞俄比亚"),
        (["天堂庄园", "考卡", "Cauca", "Paraiso"], "哥伦比亚 · 考卡 (Cauca)"),
        (["慧兰", "Huila"], "哥伦比亚 · 慧兰 (Huila)"),
        (["哥伦比亚", "Colombia"], "哥伦比亚"),
        (["肯尼亚", "Kenya"], "肯尼亚"),
        (["洪都拉斯", "雪莉", "Honduras"], "洪都拉斯"),
        (["哥斯达黎加", "Costa Rica"], "哥斯达黎加"),
        (["危地马拉", "安提瓜", "Guatemala"], "危地马拉"),
        (["云南", "保山", "普洱", "孟连", "Yunnan"], "中国 · 云南"),
        (["巴西", "Brazil"], "巴西"),
        (["曼特宁", "印尼", "苏门答腊", "Sumatra", "Indonesia"], "印度尼西亚 · 苏门答腊"),
        (["卢旺达", "Rwanda"], "卢旺达"),
    ]

    private static let processRules: [(keywords: [String], label: String)] = [
        (["双重厌氧水洗"], "双重厌氧水洗"),
        (["双重厌氧日晒"], "双重厌氧日晒"),
        (["厌氧日晒", "Anaerobic Natural"], "厌氧日晒 (Anaerobic Natural)"),
        (["厌氧水洗", "Anaerobic Washed"], "厌氧水洗 (Anaerobic Washed)"),
        (["厌氧蜜处理"], "厌氧蜜处理"),
        (["厌氧"], "厌氧发酵 (Anaerobic)"),
        (["雪莉桶", "威士忌桶", "酒桶发酵", "Barrel"], "酒桶发酵 (Barrel Aged)"),
        (["热冲击", "Thermal Shock"], "热冲击处理 (Thermal Shock)"),
        (["红蜜"], "红蜜处理 (Red Honey)"),
        (["黄蜜"], "黄蜜处理 (Yellow Honey)"),
        (["黑蜜"], "黑蜜处理 (Black Honey)"),
        (["蜜处理", "Honey"], "蜜处理 (Honey)"),
        (["湿刨", "Wet Hulled"], "湿刨法 (Wet Hulled)"),
        (["日晒", "Natural"], "日晒 (Natural)"),
        (["水洗", "Washed"], "水洗 (Washed)"),
    ]

    private static let roastRules: [(keywords: [String], label: String)] = [
        (["极浅烘", "极浅度"], "极浅烘焙"),
        (["中浅烘", "浅中烘", "中浅度", "Medium-Light"], "中浅烘焙"),
        (["中深烘", "深中烘", "中深度", "Medium-Dark"], "中深烘焙"),
        (["浅烘", "浅度烘焙", "浅度", "Light"], "浅度烘焙"),
        (["中烘", "中度烘焙", "中度", "Medium"], "中度烘焙"),
        (["深烘", "深度烘焙", "深度", "Dark"], "深度烘焙"),
    ]

    private static let flavorLexicon: [String] = [
        "草莓果酱", "奶油太妃糖", "水蜜桃酸奶", "白桃乌龙", "威士忌酒香", "香草奶油",
        "热带水果", "百香果", "水蜜桃", "佛手柑", "茉莉白花", "茉莉花", "玫瑰花",
        "太妃糖", "黑巧克力", "巧克力", "黑巧", "柑橘", "柠檬", "橙花", "白桃",
        "黄桃", "西梅", "蓝莓", "草莓", "黑莓", "树莓", "芒果", "菠萝", "荔枝",
        "葡萄", "红酒", "朗姆酒", "威士忌", "雪莉", "茉莉", "玫瑰", "白花",
        "乌龙茶", "红茶", "绿茶", "蜂蜜", "焦糖", "红糖", "奶油", "酸奶",
        "香草", "榛果", "坚果", "杏仁", "可可",
    ]

    private static let varietalOrEstateAliases: [String] = [
        "红标瑰夏", "绿标瑰夏", "蓝标瑰夏", "花魁7.0", "花魁", "瑰夏",
        "翡翠庄园", "天堂庄园", "果丁丁", "耶加雪菲", "罕贝拉", "西达摩",
        "雪莉", "曼特宁", "铁皮卡", "波旁", "粉波旁", "希爪", "卡杜拉", "SL28",
    ]

    // MARK: - Small helpers

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges > 1 else { return nil }
        let range = match.range(at: 1)
        guard range.location != NSNotFound else { return nil }
        return nsText.substring(with: range)
    }

    private static func containsMatch(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        let nsText = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) != nil
    }

    private static func replaceMatches(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let nsText = text as NSString
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: nsText.length),
            withTemplate: template
        )
    }

    private static func splitByRegex(_ pattern: String, text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var parts: [String] = []
        var cursor = 0
        for match in regex.matches(in: text, range: fullRange) {
            if match.range.location > cursor {
                parts.append(nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < nsText.length {
            parts.append(nsText.substring(with: NSRange(location: cursor, length: nsText.length - cursor)))
        }
        return parts
    }

    /// Normalizes Chinese/English roast dates ("2026年11月5日", "2026/11/05", "2026-11-05")
    /// to ISO `yyyy-MM-dd`; returns nil for missing or invalid dates.
    private static func normalizeDateStr(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #"(20\d{2})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})"#) else { return nil }
        let nsText = raw as NSString
        guard let match = regex.firstMatch(in: raw, range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges >= 4 else { return nil }
        guard let year = Int(nsText.substring(with: match.range(at: 1))),
              let month = Int(nsText.substring(with: match.range(at: 2))),
              let day = Int(nsText.substring(with: match.range(at: 3))) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func isoDateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func timeStampHHmmss() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HHmmss"
        return formatter.string(from: Date())
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded(.toNearestOrEven) / 100
    }
}
