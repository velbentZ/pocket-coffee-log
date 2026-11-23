import Foundation
import PocketCoffeeCore
import UserNotifications

/// Local notification dispatcher & tap deep-link router for completed coffee reports.
/// Delivers banners both in background and foreground, and routes notification taps
/// directly to the newly generated `ReportDetailView`.
@MainActor
final class AppNotificationManager: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = AppNotificationManager()

    var onOpenRecord: ((String) -> Void)?

    private override init() {
        super.init()
    }

    func configure(onOpenRecord: @escaping (String) -> Void) {
        self.onOpenRecord = onOpenRecord
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    func notifyReportReady(record: CoffeeRecord) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()

        if record.recordType == .equipmentProfile {
            content.title = "⚙️ 常驻咖啡设备档案已更新"
            content.body = "已收录 \(record.equipmentItems.count) 项器具，点击立即查看设备档案。"
        } else {
            let bean = record.beanName ?? "咖啡制作记录"
            let dose = record.beanWeightG.map { String(format: "%.1fg", $0) } ?? "--"
            let yield = record.yieldG.map { String(format: "%.1fg", $0) } ?? "--"
            let ratio = record.brewRatio ?? "--"
            let time: String = {
                guard let t = record.extractionTimeS, t.isFinite, t >= 0 else { return "--" }
                return "\(Int(min(t, 100_000.0)))s"
            }()
            content.title = "☕️ 咖啡制作报告已完成"
            content.body = "\(bean)｜\(dose) → \(yield) (\(ratio)) · \(time)，点击查看完整报告与小红书排版"
        }

        content.sound = .default
        content.userInfo = ["record_id": record.id]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.4, repeats: false)
        let request = UNNotificationRequest(
            identifier: "pocketcoffee-report-\(record.id)",
            content: content,
            trigger: trigger
        )
        center.add(request)
    }

    func sendTestNotification(targetRecord: CoffeeRecord?) async -> String {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else {
            return "未获得通知权限，请在系统「设置 → Pocket Coffee → 通知」中开启允许通知。"
        }

        let content = UNMutableNotificationContent()
        content.title = "☕️ Pocket Coffee 通知测试成功"
        if let targetRecord {
            let label = targetRecord.beanName ?? "最近一条报告"
            content.body = "点击此通知将直接跳转到「\(label)」报告详情页。"
            content.userInfo = ["record_id": targetRecord.id]
        } else {
            content.body = "通知权限已就绪！下次自动导入视频完成后，点击通知即可直达报告。"
        }
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.0, repeats: false)
        let request = UNNotificationRequest(
            identifier: "pocketcoffee-test-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        do {
            try await center.add(request)
            return "已发送测试通知，1 秒后将在顶部弹出横幅，点击可验证直达报告。"
        } catch {
            return "发送测试通知失败：\(error.localizedDescription)"
        }
    }

    // Show notification banner even when Pocket Coffee is currently in the foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    // Deep-link straight into the completed report when the user taps the notification
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if let rawRecordID = response.notification.request.content.userInfo["record_id"] as? String,
           let recordID = DeepLinkValidator.sanitizeRecordID(rawRecordID) {
            onOpenRecord?(recordID)
        }
    }
}
