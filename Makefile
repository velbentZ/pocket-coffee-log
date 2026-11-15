.PHONY: test snapshot server provision sync

# Run full automated test suite (pipeline + camera STA + lossless context compaction)
test:
	python3 -m unittest discover -s tests -p "test_*.py" -v

# Refresh lossless project context snapshot (.context/memory_snapshot.json & CONTEXT_SNAPSHOT.md)
snapshot:
	python3 -c "from core.context_engine import ProjectMemoryManager; import os; ProjectMemoryManager(os.getcwd()).refresh_snapshot(); print('✅ Context snapshot refreshed.')"

# Start local Web & API server on port 8788
server:
	PORT=8788 python3 server/app.py

# Provision Pocket 3 / Pocket 4 Pro into persistent LAN STA mode
provision:
	python3 daemon/provision_camera_sta.py --device pocket4p --ssid "Home_Coffee_LAN" --password "coffee123456" --lan-ip 192.168.5.108 --exec "iw dev wlan0 info && ps"
