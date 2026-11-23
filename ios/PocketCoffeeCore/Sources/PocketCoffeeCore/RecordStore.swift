import Foundation

/// Swift port of `core/store.py` (`CoffeeStore`): persistent JSON storage for coffee
/// brew reports and equipment profiles, seeded with the same three initial sample
/// records as the Python backend. Records are listed newest first and upserted by id.
public final class RecordStore: @unchecked Sendable {

    private let directoryURL: URL
    private let fileURL: URL
    private let lock = NSLock()

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.fileURL = directoryURL.appendingPathComponent("coffee_records.json")
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            writeRecordsLocked(Self.buildInitialSamples())
        }
    }

    // MARK: - Public API

    /// All records, newest first (by `createdAt`, stable for equal timestamps).
    public func listRecords() -> [CoffeeRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Self.sortedNewestFirst(loadRecordsLocked()).map {
            SandboxPathResolver.resolveRecordPaths($0)
        }
    }

    public func getRecord(id: String) -> CoffeeRecord? {
        lock.lock()
        defer { lock.unlock() }
        return loadRecordsLocked()
            .first { $0.id == id }
            .map { SandboxPathResolver.resolveRecordPaths($0) }
    }

    /// Upserts by id (replaces an existing record, inserts a new one) and keeps the
    /// persisted list ordered newest first.
    public func saveRecord(_ record: CoffeeRecord) {
        lock.lock()
        defer { lock.unlock() }
        var records = loadRecordsLocked()
        if let idx = records.firstIndex(where: { $0.id == record.id }) {
            records[idx] = record
        } else {
            records.insert(record, at: 0)
        }
        writeRecordsLocked(Self.sortedNewestFirst(records))
    }

    public func deleteRecord(id: String) {
        lock.lock()
        defer { lock.unlock() }
        var records = loadRecordsLocked()
        records.removeAll { $0.id == id }
        writeRecordsLocked(records)
    }

    // MARK: - Persistence

    private func loadRecordsLocked() -> [CoffeeRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([CoffeeRecord].self, from: data) else {
            return []
        }
        return records
    }

    private func writeRecordsLocked(_ records: [CoffeeRecord]) {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(records) {
            #if os(iOS)
            let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            #else
            let options: Data.WritingOptions = [.atomic]
            #endif
            try? data.write(to: fileURL, options: options)
        }
    }

    private static func sortedNewestFirst(_ records: [CoffeeRecord]) -> [CoffeeRecord] {
        records.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.createdAt != rhs.element.createdAt {
                    return lhs.element.createdAt > rhs.element.createdAt
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: - Initial samples (mirrors core/store.py)

    private static func buildInitialSamples() -> [CoffeeRecord] {
        // 1. Complete SOE espresso recorded by Pocket 4 Pro over LAN STA.
        var r1 = ChineseCoffeeAnalyzer.extractParameters(
            transcript:
                "我要开始制作咖啡。今天咖啡豆用的是埃塞俄比亚花魁7.0日晒中浅烘，咖啡豆称重是18.5克，"
                + "用的是额外独立磨豆机 Niche Zero，研磨度调到刻度 14.5 格。"
                + "今天做的是 SOE 单一产地意式浓缩，水温 93 度，萃取压力稳定在 9.2 bar，"
                + "萃取时间用了 29 秒，最后出液量是 37 克。好了，咖啡制作完成。",
            cameraDevice: "DJI Osmo Pocket 4 Pro",
            sourceType: .djiPocket,
            videoPath: "/storage/sdcard0/DCIM/DJI_001/DJI_20261115_094210_001.MP4"
        )
        r1.id = "brew-20261115-094210-p4p"
        r1.createdAt = "2026-11-15 09:42:10"

        // 2. Incomplete espresso missing grind setting & pressure (demonstrates the
        //    automatic missing-field alert & mobile supplement flow).
        var r2 = ChineseCoffeeAnalyzer.extractParameters(
            transcript:
                "开始做咖啡。这杯咖啡豆用的是哥伦比亚天堂庄园双重厌氧中浅烘，豆子称重 18 克，"
                + "用的是咖啡机自带磨豆机铂富内置磨，做一杯意式浓缩冰拿铁，"
                + "萃取时间 27 秒，出液是 35 克。制作结束。",
            cameraDevice: "DJI Osmo Pocket 3",
            sourceType: .djiPocket,
            videoPath: "/storage/sdcard0/DCIM/DJI_001/DJI_20261115_095012_002.MP4"
        )
        r2.id = "brew-20261115-095012-p3"
        r2.createdAt = "2026-11-15 09:50:12"

        // 3. Complete cold brew recorded by Pocket 4 Pro.
        var r3 = ChineseCoffeeAnalyzer.extractParameters(
            transcript:
                "我要开始制作咖啡。今天做一壶冷萃咖啡，咖啡豆用的是巴拿马翡翠庄园绿标瑰夏浅烘，"
                + "咖啡豆称重 45 克，用的是额外独立磨豆机 DF64，研磨度调到刻度 58 格，"
                + "注水出液量是 405 毫升，冰箱低温萃取时间 12 小时。录制结束。",
            cameraDevice: "DJI Osmo Pocket 4 Pro",
            sourceType: .djiPocket,
            videoPath: "/storage/sdcard0/DCIM/DJI_001/DJI_20261114_211500_009.MP4"
        )
        r3.id = "brew-20261114-211500-cb"
        r3.createdAt = "2026-11-14 21:15:00"

        return [r1, r2, r3]
    }
}
