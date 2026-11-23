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
import ipaddress
import json
import os
import re
import socket
import subprocess
import tempfile
from typing import Any, Dict, List, Optional, Tuple
from urllib import request as urllib_request
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse

from core.models import CoffeeRecord


REDACTED_SECRET_PLACEHOLDER = "********"
SECRET_NOTIFICATION_KEYS = (
    "wecom_webhook_url",
    "serverchan_sendkey",
    "bark_url",
    "feishu_webhook_url",
)


class _NoRedirectHandler(urllib_request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise HTTPError(req.full_url, code, "Redirects are disallowed for notification webhooks", headers, fp)


def _is_forbidden_ssrf_ip(ip_str: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip_str)
    except ValueError:
        return True
    return (
        addr.is_loopback
        or addr.is_link_local
        or addr.is_multicast
        or addr.is_unspecified
        or addr.is_reserved
        or addr.is_private
    )


def validate_webhook_url(
    url: str,
    *,
    allowed_hosts: Optional[Tuple[str, ...]] = None,
    require_https: bool = True,
    resolve_dns: bool = False,
) -> bool:
    raw = (url or "").strip()
    if not raw or any(ch in raw for ch in ("\r", "\n", "\x00")):
        return False
    parsed = urlparse(raw)
    allowed_schemes = ("https",) if require_https else ("https", "http")
    if parsed.scheme not in allowed_schemes:
        return False
    if parsed.username or parsed.password or parsed.fragment:
        return False
    host = (parsed.hostname or "").strip().lower()
    if not host or host in ("localhost", "localhost.localdomain") or host.endswith(".local"):
        return False
    try:
        ipaddress.ip_address(host)
        is_ip_literal = True
    except ValueError:
        is_ip_literal = False
    if is_ip_literal and _is_forbidden_ssrf_ip(host):
        return False
    if allowed_hosts is not None and host not in allowed_hosts:
        return False
    if parsed.port is not None and not (1 <= parsed.port <= 65535):
        return False
    if resolve_dns:
        try:
            infos = socket.getaddrinfo(host, parsed.port or (443 if parsed.scheme == "https" else 80), type=socket.SOCK_STREAM)
        except OSError:
            return False
        if not infos:
            return False
        for info in infos:
            resolved_ip = info[4][0].split("%", 1)[0]
            if _is_forbidden_ssrf_ip(resolved_ip):
                return False
    return True


def validate_mobile_base_url(url: str) -> bool:
    raw = (url or "").strip()
    if not raw:
        return True
    if any(ch in raw for ch in ("\r", "\n", "\x00")):
        return False
    parsed = urlparse(raw)
    if parsed.scheme not in ("http", "https"):
        return False
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        return False
    host = (parsed.hostname or "").strip().lower()
    if not host:
        return False
    try:
        addr = ipaddress.ip_address(host)
        if addr.is_link_local or addr.is_multicast or addr.is_unspecified:
            return False
    except ValueError:
        if not re.fullmatch(r"[a-z0-9.-]{1,253}", host):
            return False
    if parsed.port is not None and not (1 <= parsed.port <= 65535):
        return False
    return True


def validate_notification_config(cfg: Dict[str, Any]) -> Optional[str]:
    if not isinstance(cfg, dict):
        return "Notification config must be a JSON object"
    mobile_url = str(cfg.get("mobile_base_url") or "").strip()
    if mobile_url and not validate_mobile_base_url(mobile_url):
        return "Invalid mobile_base_url: must be a valid http(s) base URL"
    wecom = str(cfg.get("wecom_webhook_url") or "").strip()
    if wecom and not validate_webhook_url(wecom, allowed_hosts=("qyapi.weixin.qq.com",), require_https=True):
        return "Invalid wecom_webhook_url: must use https://qyapi.weixin.qq.com"
    feishu = str(cfg.get("feishu_webhook_url") or "").strip()
    if feishu and not validate_webhook_url(
        feishu, allowed_hosts=("open.feishu.cn", "open.larksuite.com"), require_https=True
    ):
        return "Invalid feishu_webhook_url: must use https://open.feishu.cn or https://open.larksuite.com"
    sendkey = str(cfg.get("serverchan_sendkey") or "").strip()
    if sendkey and not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", sendkey):
        return "Invalid serverchan_sendkey format"
    bark = str(cfg.get("bark_url") or "").strip()
    if bark and not validate_webhook_url(bark, require_https=True):
        return "Invalid bark_url: must be an https:// public Bark endpoint"
    return None


def redact_notification_config(cfg: Dict[str, Any]) -> Dict[str, Any]:
    out = dict(cfg or {})
    for key in SECRET_NOTIFICATION_KEYS:
        if out.get(key):
            out[key] = REDACTED_SECRET_PLACEHOLDER
    return out


class NotificationManager:
    def __init__(self, data_dir: str):
        self.data_dir = data_dir
        self.config_path = os.path.join(data_dir, "notification_config.json")
        self.history_path = os.path.join(data_dir, "notification_history.json")
        self._ensure_defaults()

    @staticmethod
    def _atomic_write_json(path: str, payload: Any, mode: int = 0o600) -> None:
        parent = os.path.dirname(path)
        os.makedirs(parent, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(prefix=".notif-", dir=parent)
        try:
            os.chmod(tmp_path, mode)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False, indent=2)
            os.replace(tmp_path, path)
        finally:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)

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
            self._atomic_write_json(self.config_path, default_cfg, mode=0o600)
        if not os.path.exists(self.history_path):
            self._atomic_write_json(self.history_path, [], mode=0o600)

    def load_config(self) -> Dict[str, Any]:
        with open(self.config_path, "r", encoding="utf-8") as f:
            return json.load(f)

    def save_config(self, cfg: Dict[str, Any]) -> None:
        self._atomic_write_json(self.config_path, cfg, mode=0o600)

    def get_history(self) -> List[Dict[str, Any]]:
        try:
            with open(self.history_path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return []

    def notify_brew_record(self, rec: CoffeeRecord) -> Dict[str, Any]:
        cfg = self.load_config()
        raw_base_url = str(cfg.get("mobile_base_url") or "http://192.168.5.84:8788").strip()
        base_url = (raw_base_url if validate_mobile_base_url(raw_base_url) else "http://192.168.5.84:8788").rstrip("/")
        safe_rec_id = quote(str(rec.id or ""), safe="-_")
        report_url = f"{base_url}/?record_id={safe_rec_id}"

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

        # 1. macOS Native Notification via parameterized AppleScript argv (immune to quote/backslash injection)
        if cfg.get("enable_macos_banner", True):
            try:
                safe_title = re.sub(r"[\r\n\x00]+", " ", title)[:120]
                raw_sub = rec.extraction_diagnosis[:60] if rec.extraction_diagnosis else summary[:60]
                safe_sub = re.sub(r"[\r\n\x00]+", " ", raw_sub)[:120]
                subprocess.run(
                    [
                        "osascript",
                        "-e",
                        "on run argv\ndisplay notification (item 1 of argv) with title (item 2 of argv)\nend run",
                        "--",
                        safe_sub,
                        safe_title,
                    ],
                    timeout=2,
                    check=False,
                )
                channels_used.append("macOS / iCloud 通知横幅")
            except Exception:
                pass

        # 2. Enterprise WeChat (企业微信机器人)
        wecom_url = str(cfg.get("wecom_webhook_url") or "").strip()
        if wecom_url and validate_webhook_url(
            wecom_url, allowed_hosts=("qyapi.weixin.qq.com",), require_https=True, resolve_dns=True
        ):
            payload = {
                "msgtype": "markdown",
                "markdown": {
                    "content": f"### {title}\n{summary}\n> 录制设备：`{rec.camera_device}` (STA 局域网直传)"
                },
            }
            if self._post_json(wecom_url, payload):
                channels_used.append("企业微信机器人")

        # 3. ServerChan (Server酱微信推送)
        sendkey = str(cfg.get("serverchan_sendkey") or "").strip()
        if sendkey and re.fullmatch(r"[A-Za-z0-9_-]{1,128}", sendkey):
            sc_url = f"https://sctapi.ftqq.com/{sendkey}.send"
            if validate_webhook_url(sc_url, allowed_hosts=("sctapi.ftqq.com",), require_https=True, resolve_dns=True):
                if self._post_json(sc_url, {"title": title, "desp": summary}):
                    channels_used.append("微信 Server酱")

        # 4. Bark (iOS Push)
        bark_url = str(cfg.get("bark_url") or "").strip()
        if bark_url and validate_webhook_url(bark_url, require_https=True, resolve_dns=True):
            b_endpoint = f"{bark_url.rstrip('/')}/{move_url_safe(title)}/{move_url_safe(summary)}?url={quote(report_url, safe='')}"
            try:
                opener = urllib_request.build_opener(
                    urllib_request.HTTPSHandler(), _NoRedirectHandler()
                )
                req = urllib_request.Request(b_endpoint, method="GET")
                with opener.open(req, timeout=3) as resp:
                    if 200 <= resp.status < 300:
                        channels_used.append("Bark (iOS)")
            except Exception:
                pass

        # 5. Feishu Webhook
        feishu_url = str(cfg.get("feishu_webhook_url") or "").strip()
        if feishu_url and validate_webhook_url(
            feishu_url, allowed_hosts=("open.feishu.cn", "open.larksuite.com"), require_https=True, resolve_dns=True
        ):
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
        self._atomic_write_json(self.history_path, history, mode=0o600)

        rec.notification_sent = True
        return entry

    def _post_json(self, url: str, data: Dict[str, Any]) -> bool:
        if not validate_webhook_url(url, require_https=True, resolve_dns=True):
            return False
        try:
            opener = urllib_request.build_opener(
                urllib_request.HTTPSHandler(), _NoRedirectHandler()
            )
            body = json.dumps(data).encode("utf-8")
            req = urllib_request.Request(
                url,
                data=body,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with opener.open(req, timeout=3) as resp:
                return 200 <= resp.status < 300
        except Exception:
            return False


def move_url_safe(text: str) -> str:
    return quote(text.replace("/", " "), safe="")
