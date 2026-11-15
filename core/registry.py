"""
Plugin & Event Bus Registry for Modular Architecture.

Allows decoupled registration and discovery of:
- CameraDrivers (`duml_sta`, `adb_shell`, `uvc_stream`)
- ParameterExtractors (`regex_cn`, `llm_multimodal`, `ocr_scale`)
- BaristaAdvisors (`espresso_advisor`, `cold_brew_advisor`)
- SocialRenderers (`xiaohongshu`, `wechat_moments`)
- NotificationAdapters (`wecom`, `serverchan`, `bark`, `feishu`, `macos`)
"""

from typing import Any, Callable, Dict, List, Optional


class EventBus:
    """Synchronous/Asynchronous in-process pub-sub event bus for decoupled modules."""

    def __init__(self) -> None:
        self._subscribers: Dict[str, List[Callable[[Dict[str, Any]], None]]] = {}
        self._event_history: List[Dict[str, Any]] = []

    def subscribe(self, topic: str, handler: Callable[[Dict[str, Any]], None]) -> None:
        self._subscribers.setdefault(topic, []).append(handler)

    def publish(self, topic: str, payload: Dict[str, Any]) -> int:
        event = {"topic": topic, "payload": payload}
        self._event_history.append(event)
        self._event_history = self._event_history[-100:]
        handlers = self._subscribers.get(topic, [])
        for h in handlers:
            h(payload)
        return len(handlers)

    def recent_events(self, limit: int = 20) -> List[Dict[str, Any]]:
        return self._event_history[-limit:]


class ModuleRegistry:
    """Central registry for pluggable drivers, extractors, advisors, and notifiers."""

    def __init__(self) -> None:
        self._components: Dict[str, Dict[str, Any]] = {
            "camera_driver": {},
            "extractor": {},
            "advisor": {},
            "renderer": {},
            "notifier": {},
        }

    def register(self, category: str, name: str, component: Any, metadata: Optional[Dict[str, Any]] = None) -> None:
        if category not in self._components:
            self._components[category] = {}
        self._components[category][name] = {
            "name": name,
            "component": component,
            "metadata": metadata or {},
        }

    def get(self, category: str, name: str) -> Any:
        entry = self._components.get(category, {}).get(name)
        return entry["component"] if entry else None

    def list_category(self, category: str) -> List[Dict[str, Any]]:
        return [
            {"name": k, "metadata": v["metadata"]}
            for k, v in self._components.get(category, {}).items()
        ]

    def summary(self) -> Dict[str, List[str]]:
        return {cat: list(items.keys()) for cat, items in self._components.items()}


# Global singleton instances for easy cross-module wiring
global_event_bus = EventBus()
global_registry = ModuleRegistry()
