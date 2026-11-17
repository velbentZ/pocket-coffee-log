"""
Mobile Notification & Missing Parameter Reminder Dispatcher.

Supports:
1. WeCom / Enterprise WeChat Webhook (企业微信机器人)
2. ServerChan (Server酱微信推送: sctapi.ftqq.com)
3. Bark (iOS 强提醒推送)
4. Feishu / Lark Webhook (飞书机器人)
5. macOS Local Notification (`osascript`) + Interactive Mobile Web Push Card

Automatically differentiates between:
- Complete Brew Report Notification ("☕️ 您的咖啡萃取报告已生成，点击查看精美卡片与小红书分享文案")
- Missing Parameter Supplement Reminder ("⚠️ 咖啡报告缺少【萃取压力、研磨度】，点击在手机上一键补充")
"""

from datetime import datetime
import json
import os
import subprocess
from typing import Any, Dict, List, Optional
from urllib import request as urllib_request
from urllib.error import URLError

from core.models import CoffeeRecord


class NotificationManager:
    def __init__(self, data_dir: str):
        self.data_dir = data_dir
        self.config_path = os.path.join(data_dir, "notification_config.json")
        self.history_path = os.path.join(data_dir, "notification_history.json")
        self._ensure_defaults()

    def _ensure_defaults(self) -> None:
        os.makedirs(self.data_dir, exist_ok=True)
        if not os.path.exists(self.config_path):
            default_cfg = {
                "mobile_base_url": "http://192.168.5.84:8788",
                "enable_macos_banner": True,
                "wecom_webhook_url": os.environ.get("WECOM_WEBHOOK_URL", ""),
                "serverchan_sendkey": os.environ.get("SERVERCHAN_SENDKEY", ""),
                "bark_url": os.environ.get("BARK_URL", ""),
                "feishu_webhook_url": os.environ.get("FEISHU_WEBHOOK_URL", ""),
            }
            with open(self.config_path, "w", encoding="utf-8") as f:
                json.dump(default_cfg, f, ensure_ascii=False, indent=2)
        if not os.path.exists(self.history_path):
            with open(self.history_path, "w", encoding="utf-8") as f:
                json.dump([], f, ensure_ascii=False, indent=2)

    def load_config(self) -> Dict[str, Any]:
        with open(self.config_path, "r", encoding="utf-8") as f:
            return json.load(f)

    def save_config(self, cfg: Dict[str, Any]) -> None:
        with open(self.config_path, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)

    def get_history(self) -> List[Dict[str, Any]]:
        try:
            with open(self.history_path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return []

    def notify_brew_record(self, rec: CoffeeRecord) -> Dict[str, Any]:
        cfg = self.load_config()
        base_url = cfg.get("mobile_base_url", "http://192.168.5.84:8788").rstrip("/")
        report_url = f"{base_url}/?record_id={rec.id}"

        if rec.status == "needs_info" and rec.missing_fields:
            missing_labels = "、".join(m["label"] for m in rec.missing_fields)
            title = f"⚠️ 咖啡记录待补全 ({len(rec.missing_fields)}项缺失)"
            summary = (
                f"相机 ({rec.camera_device}) 已完成视频与语音分析，但未识别到：{missing_labels}。\n"
                f"已识别豆子：{rec.bean_name or '待确认'} ({rec.bean_weight_g or '--'}g)。\n"
                f"👉 点击通知直接在手机端语音或点选补全：{report_url}&action=supplement"
            )
            level = "warning"
        else:
            title = f"☕️ 咖啡制作报告已生成｜{rec.bean_name or '今日咖啡'}"
            summary = (
                f"【{rec.brew_method or '意式浓缩'}】{rec.bean_weight_g or '--'}g 粉 → {rec.yield_g or '--'}g 液 ({rec.brew_ratio or '1:2.0'})\n"
                f"磨豆：{rec.grinder_type or ''} {rec.grinder_model or ''} ({rec.grind_setting or '--'})\n"
                f"萃取：{rec.extraction_time_s or '--'}s @ {rec.pressure_bar or '--'} bar\n"
                f"👉 点击查看精美海报并一键分享小红书/微信：{report_url}"
            )
            level = "success"

        channels_used = ["Web 手机端实时提醒中心"]

        # 1. macOS Native Notification (also mirrors to iPhone via Apple Handoff/Notifications if enabled)
        if cfg.get("enable_macos_banner", True):
            try:
                safe_title = title.replace('"', '\\"')
                safe_sub = (rec.extraction_diagnosis[:60] if rec.extraction_diagnosis else summary[:60]).replace('"', '\\"')
                subprocess.run(
                    ["osascript", "-e", f'display notification "{safe_sub}" with title "{safe_title}"'],
                    timeout=2,
                    check=False,
                )
                channels_used.append("macOS / iCloud 通知横幅")
            except Exception:
                pass

        # 2. Enterprise WeChat (企业微信机器人)
        wecom_url = cfg.get("wecom_webhook_url", "").strip()
        if wecom_url:
            payload = {
                "msgtype": "markdown",
                "markdown": {
                    "content": f"### {title}\n{summary}\n> 录制设备：`{rec.camera_device}` (STA 局域网直传)"
                },
            }
            if self._post_json(wecom_url, payload):
                channels_used.append("企业微信机器人")

        # 3. ServerChan (Server酱微信推送)
        sendkey = cfg.get("serverchan_sendkey", "").strip()
        if sendkey:
            sc_url = f"https://sctapi.ftqq.com/{sendkey}.send"
            if self._post_json(sc_url, {"title": title, "desp": summary}):
                channels_used.append("微信 Server酱")

        # 4. Bark (iOS Push)
        bark_url = cfg.get("bark_url", "").strip()
        if bark_url:
            b_endpoint = f"{bark_url.rstrip('/')}/{ move_url_safe(title) }/{ move_url_safe(summary) }?url={report_url}"
            try:
                req = urllib_request.Request(b_endpoint, method="GET")
                urllib_request.urlopen(req, timeout=3)
                channels_used.append("Bark (iOS)")
            except Exception:
                pass

        # 5. Feishu Webhook
        feishu_url = cfg.get("feishu_webhook_url", "").strip()
        if feishu_url:
            payload = {
                "msg_type": "text",
                "content": {"text": f"{title}\n\n{summary}"},
            }
            if self._post_json(feishu_url, payload):
                channels_used.append("飞书机器人")

        entry = {
            "id": f"notif-{datetime.now().strftime('%H%M%S')}",
            "time": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "record_id": rec.id,
            "level": level,
            "title": title,
            "summary": summary,
            "report_url": report_url,
            "missing_fields": rec.missing_fields,
            "channels": channels_used,
        }

        history = self.get_history()
        history.insert(0, entry)
        history = history[:30]
        with open(self.history_path, "w", encoding="utf-8") as f:
            json.dump(history, f, ensure_ascii=False, indent=2)

        rec.notification_sent = True
        return entry

    def _post_json(self, url: str, data: Dict[str, Any]) -> bool:
        try:
            body = json.dumps(data).encode("utf-8")
            req = urllib_request.Request(
                url,
                data=body,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib_request.urlopen(req, timeout=3) as resp:
                return 200 <= resp.status < 300
        except Exception:
            return False


def move_url_safe(text: str) -> str:
    from urllib.parse import quote
    return quote(text.replace("/", " "), safe="")
