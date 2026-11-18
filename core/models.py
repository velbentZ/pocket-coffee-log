"""Data models and schema validation for Pocket Coffee Log."""

from dataclasses import dataclass, field, asdict
from datetime import datetime
from typing import Dict, List, Optional, Any
import uuid


REQUIRED_BREW_FIELDS = [
    ("bean_name", "咖啡豆名称/产地"),
    ("bean_weight_g", "咖啡豆称重 (g)"),
    ("grind_setting", "研磨度刻度"),
    ("grinder_type", "研磨机器 (独立磨豆机/自带磨豆机)"),
    ("grinder_model", "磨豆机具体型号"),
    ("brew_method", "制作方式 (意式浓缩 Espresso / 冷萃 Cold Brew / 美式 / 拿铁)"),
    ("yield_g", "萃取液重/出液量 (g/ml)"),
    ("extraction_time_s", "萃取时间 (s)"),
    ("pressure_bar", "萃取压力 (bar)"),
]


@dataclass
class FlavorProfile:
    """Radar chart scores (1-10) for coffee sensory evaluation."""
    acidity: float = 6.5      # 酸质
    sweetness: float = 7.5    # 甜感
    body: float = 7.8         # 醇厚度
    aroma: float = 8.2        # 香气
    aftertaste: float = 7.5   # 余韵
    balance: float = 7.6      # 平衡感


@dataclass
class VideoEvent:
    """Visual/Audio milestone detected during Pocket 3 / Pocket 4 Pro recording."""
    timestamp_s: float
    stage: str
    description: str
    confidence: float = 0.95


@dataclass
class CoffeeRecord:
    """Complete coffee brewing session record."""
    id: str = field(default_factory=lambda: f"brew-{datetime.now().strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:4]}")
    created_at: str = field(default_factory=lambda: datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    camera_device: str = "DJI Osmo Pocket 4 Pro"  # or "DJI Osmo Pocket 3"
    video_path: Optional[str] = None
    media_url: Optional[str] = None
    transcript: str = ""

    # Core parameters requested by user
    bean_name: Optional[str] = None              # 什么咖啡豆 (名称/庄园/处理法/烘焙度)
    bean_roast: Optional[str] = None             # 烘焙度 (浅烘/中浅烘/中深烘/深烘)
    bean_weight_g: Optional[float] = None        # 咖啡豆称重 (g)
    grind_setting: Optional[str] = None          # 研磨度是多少
    grinder_type: Optional[str] = None           # 额外的独立磨豆机 还是 咖啡机自身自带
    grinder_model: Optional[str] = None          # 磨豆机型号 (如 Niche Zero / DF64 / Breville 内置)
    brew_method: Optional[str] = None            # 意式浓缩 (Espresso) 还是 冷萃 (Cold Brew) 等
    yield_g: Optional[float] = None              # 出液是多少 (g / ml)
    extraction_time_s: Optional[float] = None    # 萃取时间是多少 (秒 或 小时)
    pressure_bar: Optional[float] = None         # 萃取压力是多少 (bar)
    water_temp_c: Optional[float] = None         # 水温 (°C)
    brew_ratio: Optional[str] = None             # 粉液比 (例如 1:2.0)

    # AI analysis & suggestions
    extraction_diagnosis: str = ""
    suggestions: List[str] = field(default_factory=list)
    xiaohongshu_copy: str = ""
    wechat_copy: str = ""
    flavor_notes: List[str] = field(default_factory=list)
    flavor_profile: Dict[str, float] = field(default_factory=lambda: asdict(FlavorProfile()))
    timeline_events: List[Dict[str, Any]] = field(default_factory=list)
    keyframes: List[Dict[str, Any]] = field(default_factory=list)

    # Status & missing info tracking
    missing_fields: List[Dict[str, str]] = field(default_factory=list)
    status: str = "complete"  # "complete" | "needs_info"
    notification_sent: bool = False

    def compute_derived_metrics(self) -> None:
        """Compute brew ratio and check for missing fields."""
        if self.bean_weight_g and self.yield_g and self.bean_weight_g > 0:
            ratio = round(self.yield_g / self.bean_weight_g, 2)
            self.brew_ratio = f"1:{ratio}"

        missing = []
        for key, label in REQUIRED_BREW_FIELDS:
            val = getattr(self, key, None)
            # For cold brew, pressure_bar is naturally 0 or N/A (ambient pressure)
            if key == "pressure_bar" and self.brew_method and "冷萃" in self.brew_method:
                if val is None:
                    self.pressure_bar = 1.0  # 常压浸泡 1 bar
                    continue
            if val is None or (isinstance(val, str) and not val.strip()):
                missing.append({"field": key, "label": label})

        self.missing_fields = missing
        self.status = "needs_info" if missing else "complete"

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "CoffeeRecord":
        valid_keys = {f.name for f in cls.__dataclass_fields__.values()}
        filtered = {k: v for k, v in data.items() if k in valid_keys}
        return cls(**filtered)
