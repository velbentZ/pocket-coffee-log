// Camera STA/USB bridge, media pull & mobile notification settings
async function probeUsbDevices() {
  const res = await fetch('/api/camera/usb_probe');
  const data = await res.json();
  appState.usb_status = data;
  renderBeansTab();
  showToast(`🔍 USB 扫描完成：串口 [${(data.serial_ports || []).join(', ') || '无'}]`);
}

async function refreshCameraStatus(deviceId = '') {
  const btn = document.getElementById('btnRefreshCameraSta');
  const tsEl = document.getElementById('cameraRefreshTimestamp');
  if (btn) {
    btn.disabled = true;
    btn.textContent = '⏳ 正在刷新相机状态...';
  }
  try {
    const [staRes, usbRes] = await Promise.all([
      fetch('/api/camera/sta'),
      fetch('/api/camera/usb_probe')
    ]);
    const staData = await staRes.json();
    const usbData = await usbRes.json();
    await fetchState();
    if (usbData && usbData.ok) {
      appState.usb_status = usbData;
      renderBeansTab();
    }
    const nowStr = new Date().toLocaleTimeString('zh-CN', { hour12: false });
    if (tsEl) {
      tsEl.textContent = `✓ 最近刷新: ${nowStr}`;
    }
    const targetCam = (staData.cameras && staData.cameras[deviceId || 'pocket4p']) || {};
    const hb = targetCam.last_heartbeat ? targetCam.last_heartbeat.slice(11, 19) : '暂无';
    const ip = (targetCam.verification && targetCam.verification.verified_sta_ip) || targetCam.lan_ip || '未分配';
    showToast(`🔄 相机状态已刷新：IP ${ip} | 最近心跳 ${hb}`);
  } catch (err) {
    showToast(`❌ 刷新相机状态失败: ${err}`);
  } finally {
    if (btn) {
      btn.disabled = false;
      btn.textContent = '🔄 刷新相机实时状态';
    }
  }
}

function renderCameraTab() {
  const camData = appState.camera_sta || {};
  const cameras = camData.cameras || {};
  const grid = document.getElementById('cameraNodesGrid');

  grid.innerHTML = Object.values(cameras).map(c => {
    const v = c.verification || {};
    const staVerified = Boolean(v.sta_connection_verified && v.heartbeat_verified);
    const safeDevId = escapeHtml(c.device_id || '');
    const verifiedIp = v.verified_sta_ip || c.lan_ip || '';
    const rawMediaUrl = c.latest_media_url || v.media_http_url || '';
    const mediaUrl = sanitizeMediaUrl(rawMediaUrl);
    const mediaDisplay = rawMediaUrl || (verifiedIp ? `http://${verifiedIp}:${c.http_media_port || 8088}/DJI_001/` : '未就绪');
    const persistenceStatus = v.persistence_status || (v.persistence_verified ? 'verified' : 'not_tested');
    const persistenceNote = v.note || '尚未执行实机 ADB 与 STA 心跳核验。';
    const daemonLabel = [
      c.internal_daemon_version || '未部署',
      c.battery_percent !== null && c.battery_percent !== undefined ? `电量 ${c.battery_percent}%` : null,
      c.sd_free_gb !== null && c.sd_free_gb !== undefined ? `剩余 ${c.sd_free_gb}GB` : null
    ].filter(Boolean).join(' · ');

    const statusBadge = c.recording_state === 'recording'
      ? `<span class="badge badge-warn">🔴 正在录制 (${escapeHtml(c.wifi_mode)})</span>`
      : (staVerified
        ? `<span class="badge badge-ok">🟢 STA 实测在线 (${escapeHtml(v.status || 'live_sta_heartbeat')})</span>`
        : `<span class="badge badge-warn">⚪ ${escapeHtml(v.status || c.wifi_mode || '未验证')}</span>`);

    const previewBtnHtml = mediaUrl
      ? `<button class="btn btn-primary" type="button" data-device-id="${safeDevId}" data-media-url="${escapeHtml(mediaUrl)}" onclick="previewCameraMedia(this.dataset.deviceId, this.dataset.mediaUrl)">🎬 预览相机 :8088 视频</button>`
      : `<button class="btn" type="button" data-device-id="${safeDevId}" onclick="previewCameraMedia(this.dataset.deviceId, '')">🔄 探测相机 :8088 媒体列表</button>`;

    return `
      <div class="camera-card">
        <div class="camera-card-head">
          <h3>📷 ${escapeHtml(c.model)} ${v.usb_product ? `<span style="font-size:12px; color:var(--crema); font-weight:500;">(${escapeHtml(v.usb_product)})</span>` : ''}</h3>
          <div style="display:flex; align-items:center; gap:8px; flex-wrap:wrap;">
            ${statusBadge}
            <button class="btn" type="button" style="padding:4px 10px; font-size:12px;" data-device-id="${safeDevId}" onclick="refreshCameraStatus(this.dataset.deviceId)">🔄 刷新状态</button>
          </div>
        </div>

        <div class="kv-list">
          <div class="kv-item"><span>实测 STA IP (verified_sta_ip)</span><code>${escapeHtml(verifiedIp || '未分配')}</code></div>
          <div class="kv-item"><span>最近心跳 (last_heartbeat)</span><code>${escapeHtml(c.last_heartbeat ? String(c.last_heartbeat).slice(0, 19).replace('T', ' ') : '暂无心跳')}</code></div>
          <div class="kv-item"><span>无线网卡 MAC (mac_address)</span><code>${escapeHtml(c.mac_address || '未采集')}</code></div>
          <div class="kv-item"><span>连接路由器 SSID / ADB 序列号</span><code>${escapeHtml(c.ssid || '--')} / ${escapeHtml(c.adb_serial || '--')}</code></div>
          <div class="kv-item" style="grid-column: 1 / -1;"><span>:8088 HTTP 媒体直拉地址 (media_http_url)</span><code>${escapeHtml(mediaDisplay)}</code></div>
          <div class="kv-item" style="grid-column: 1 / -1;"><span>内部守护进程 (/data/pocket-coffee)</span><code>${escapeHtml(daemonLabel)}</code></div>
        </div>

        <div class="persistence-box">
          <div><strong style="color:var(--accent-amber);">🔒 持久化边界 (persistence_status):</strong> <code>${escapeHtml(persistenceStatus)}</code></div>
          <div style="margin-top:4px; color:var(--text-muted); line-height:1.45;">${escapeHtml(persistenceNote)}</div>
        </div>

        <div style="display:flex; gap:8px; flex-wrap:wrap;">
          <button class="btn" type="button" data-device-id="${safeDevId}" onclick="refreshCameraStatus(this.dataset.deviceId)">🔄 刷新相机状态</button>
          ${previewBtnHtml}
          <button class="btn btn-primary" type="button" data-device-id="${safeDevId}" onclick="pullLatestMediaAndKeyframes(this.dataset.deviceId)">⬇️ 无线拉取最新 MP4 并截取 4 阶段关键帧</button>
          <button class="btn" type="button" data-device-id="${safeDevId}" onclick="triggerCameraShutter(this.dataset.deviceId, 'start')">▶️ 触发开录 (DUML 02:02)</button>
          <button class="btn btn-danger" type="button" data-device-id="${safeDevId}" onclick="triggerCameraShutter(this.dataset.deviceId, 'stop')">⏹️ 停止录制</button>
        </div>

        <!-- OsmoDesk Gimbal Preset Controls -->
        <div class="gimbal-preset-box">
          <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:6px;">
            <strong style="font-size:12.5px; color:var(--crema-bright);">🎯 OsmoDesk 云台机位预设 (DUML 04:14 · 支持口述阶段自动跟拍)</strong>
            <span style="font-size:11px; color:var(--text-muted);">语音识别「称豆 / 刻度 / 萃取 / 出液」自动联动</span>
          </div>
          <div class="gimbal-btn-grid">
            <button class="btn-gimbal" type="button" data-device-id="${safeDevId}" onclick="moveCameraGimbal(this.dataset.deviceId, 'reset_center')">P0 回中</button>
            <button class="btn-gimbal" type="button" data-device-id="${safeDevId}" onclick="moveCameraGimbal(this.dataset.deviceId, 'scale_dose')">P1 电子秤称豆</button>
            <button class="btn-gimbal" type="button" data-device-id="${safeDevId}" onclick="moveCameraGimbal(this.dataset.deviceId, 'grinder_dial')">P2 磨豆刻度</button>
            <button class="btn-gimbal" type="button" data-device-id="${safeDevId}" onclick="moveCameraGimbal(this.dataset.deviceId, 'espresso_gauge')">P3 压力表油脂</button>
            <button class="btn-gimbal" type="button" data-device-id="${safeDevId}" onclick="moveCameraGimbal(this.dataset.deviceId, 'final_cup')">P4 出杯读秒</button>
          </div>
          <div id="gimbalStatus_${safeDevId}" role="status" aria-live="polite" style="font-size:11.5px; color:var(--text-muted); margin-top:6px;"></div>
        </div>

        <div id="mediaPreview_${safeDevId}"></div>
      </div>
    `;
  }).join('');

  const logs = camData.command_log || [];
  document.getElementById('cameraTerminal').innerHTML = logs.map(l => `
    <div class="log-line">
      <div class="log-meta">[${escapeHtml(l.time)}] root@${escapeHtml(l.target)} $ ${escapeHtml(l.cmd)}</div>
      <pre>${escapeHtml(l.output)}</pre>
    </div>
  `).join('');

  document.getElementById('onCameraScriptCode').textContent = appState.on_camera_script || '';
}

async function moveCameraGimbal(deviceId, preset) {
  const statusEl = document.getElementById(`gimbalStatus_${deviceId}`);
  if (statusEl) statusEl.textContent = `⏳ 正在向 ${deviceId} 发送云台机位预设 [${preset}]...`;
  try {
    const res = await fetch('/api/camera/gimbal', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ device_id: deviceId, preset })
    });
    const data = await res.json();
    await fetchState();
    const afterEl = document.getElementById(`gimbalStatus_${deviceId}`);
    const angleInfo = (data.pitch_deg !== undefined) ? `Pitch ${data.pitch_deg}° / Yaw ${data.yaw_deg}°` : '';
    const hexInfo = data.duml_hex ? ` | DUML: ${data.duml_hex}` : '';
    const transportNote = data.ok
      ? `✅ 已下发 [${data.label || preset}] (${angleInfo})${hexInfo}`
      : `⚠️ 已生成指令帧 [${data.label || preset}] (${angleInfo}) · ${data.error || '传输待连接'}${hexInfo}`;
    if (afterEl) afterEl.textContent = transportNote;
    showToast(data.ok ? `🎯 云台指令已发送：${data.label || preset}` : `🎯 云台预设帧已构造 (${data.label || preset})`);
  } catch (err) {
    if (statusEl) statusEl.textContent = `❌ 云台指令请求失败: ${err}`;
  }
}

async function pullLatestMediaAndKeyframes(deviceId) {
  const container = document.getElementById(`mediaPreview_${deviceId}`);
  if (container) {
    container.innerHTML = `<div class="media-preview-drawer">⏳ 正在从相机 <code>:8088</code> 无线拉取最新 MP4 到本地缓存并执行 FFmpeg 4 阶段关键帧抽帧...</div>`;
  }
  try {
    const res = await fetch('/api/camera/pull_media', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ device_id: deviceId, extract_keyframes: true })
    });
    const data = await res.json();
    if (!data.ok) {
      if (container) {
        container.innerHTML = `<div class="media-preview-drawer" style="color:var(--accent-amber); font-size:12.5px;">⚠️ 无线拉取未完成：${escapeHtml(data.error || '相机暂未就绪或无 MP4 文件')}</div>`;
      }
      showToast(`⚠️ 拉取提示: ${data.error || '暂无可拉取视频'}`);
      return;
    }
    const meta = data.video_metadata || {};
    const kfs = data.keyframes || meta.keyframes || [];
    const kfCardsHtml = kfs.map(kf => {
      const imgHtml = kf.extracted && kf.image_path
        ? `<img src="/api/media/keyframe?path=${encodeURIComponent(kf.image_path)}" alt="${escapeHtml(kf.stage)}" loading="lazy" />`
        : `<div style="margin-top:6px; padding:14px 8px; text-align:center; background:#100c0a; border-radius:6px; color:var(--text-muted);">计划时间点 ${escapeHtml(kf.timestamp_s)}s (${escapeHtml(meta.fallback_reason || '待抽帧')})</div>`;
      return `
        <div class="keyframe-card">
          <div style="color:var(--crema-bright); font-weight:700;">${escapeHtml(kf.percentage)}% · t=${escapeHtml(kf.timestamp_s)}s</div>
          <div style="color:var(--latte); margin-top:2px;">${escapeHtml(kf.stage)}</div>
          ${imgHtml}
        </div>
      `;
    }).join('');

    if (container) {
      const safePullUrl = sanitizeMediaUrl(data.media_url || '');
      const safeDevId = escapeHtml(deviceId);
      container.innerHTML = `
        <div class="media-preview-drawer">
          <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:8px;">
            <strong style="font-size:13px; color:#74c69d;">✅ 已无线拉取最新 MP4 并完成 4 阶段关键帧定位</strong>
            ${safePullUrl ? `<button class="btn btn-primary" style="padding:5px 10px; font-size:12px;" type="button" data-device-id="${safeDevId}" data-media-url="${escapeHtml(safePullUrl)}" onclick="triggerMediaWebhook(this.dataset.deviceId, this.dataset.mediaUrl)">⚡ 用此视频生成完整咖啡报告</button>` : ''}
          </div>
          <div style="font-size:11.5px; color:var(--text-muted); margin-top:4px;">
            本地路径: <code>${escapeHtml(data.local_path || '')}</code>
            | 大小: <code>${data.size_bytes ? (Number(data.size_bytes) / (1024 * 1024)).toFixed(2) + ' MB' : '--'}</code>
            | 分辨率/时长: <code>${escapeHtml(meta.resolution || '--')} / ${escapeHtml(meta.duration_s ?? '--')}s</code>
          </div>
          <div class="keyframe-grid">${kfCardsHtml}</div>
        </div>
      `;
    }
    showToast('⬇️ 已无线拉取相机最新 MP4 并完成 4 阶段关键帧提取！');
  } catch (err) {
    if (container) {
      container.innerHTML = `<div class="media-preview-drawer" style="color:var(--accent-red); font-size:12px;">无线拉取异常: ${escapeHtml(err)}</div>`;
    }
  }
}

async function previewCameraMedia(deviceId, fallbackUrl) {
  const container = document.getElementById(`mediaPreview_${deviceId}`);
  if (!container) return;
  const safeDevId = escapeHtml(deviceId);
  container.innerHTML = `<div class="media-preview-drawer">⏳ 正在从 <code>/api/camera/media?device_id=${safeDevId}</code> 获取相机 :8088 最新媒体列表...</div>`;

  try {
    const res = await fetch(`/api/camera/media?device_id=${encodeURIComponent(deviceId)}`);
    const data = await res.json();
    const activeUrl = sanitizeMediaUrl(data.latest_media_url || fallbackUrl || '');
    const files = data.files || [];
    const fileListHtml = files.slice(0, 5).map(f => {
      const fUrl = sanitizeMediaUrl(f.url || '');
      return `
      <div style="display:flex; justify-content:space-between; align-items:center; padding:5px 0; border-bottom:1px dashed rgba(212,163,115,0.14); font-size:12px;">
        <code>${escapeHtml(f.name)} (${f.size_bytes ? (Number(f.size_bytes) / (1024 * 1024)).toFixed(2) + ' MB' : 'MP4'})</code>
        <div style="display:flex; gap:6px;">
          ${fUrl ? `<a class="btn" style="padding:4px 8px; font-size:11.5px; text-decoration:none;" href="${escapeHtml(fUrl)}" target="_blank" rel="noopener noreferrer">⬇️ 直拉下载</a>` : ''}
          ${fUrl ? `<button class="btn btn-primary" type="button" style="padding:4px 8px; font-size:11.5px;" data-device-id="${safeDevId}" data-media-url="${escapeHtml(fUrl)}" onclick="triggerMediaWebhook(this.dataset.deviceId, this.dataset.mediaUrl)">⚡ 解析成咖啡报告</button>` : ''}
        </div>
      </div>
    `;
    }).join('');

    if (!activeUrl) {
      container.innerHTML = `
        <div class="media-preview-drawer">
          <div style="font-size:12.5px; color:var(--accent-amber);">当前相机暂未上报可用的 :8088 MP4 地址（目录: <code>${escapeHtml(data.dcim_root || '/mnt/media_rw/emulated/DCIM/DJI_001')}</code>）。</div>
        </div>
      `;
      return;
    }

    const safeActiveUrl = escapeHtml(activeUrl);
    container.innerHTML = `
      <div class="media-preview-drawer">
        <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:8px;">
          <strong style="font-size:13px; color:#74c69d;">🎬 相机内部 BusyBox :8088 实测视频直拉预览</strong>
          <div style="display:flex; gap:8px;">
            <a class="btn" style="padding:5px 10px; font-size:12px; text-decoration:none;" href="${safeActiveUrl}" target="_blank" rel="noopener noreferrer">🔗 在新窗口打开/下载 MP4</a>
            <button class="btn btn-primary" type="button" style="padding:5px 10px; font-size:12px;" data-device-id="${safeDevId}" data-media-url="${safeActiveUrl}" onclick="triggerMediaWebhook(this.dataset.deviceId, this.dataset.mediaUrl)">⚡ 用此视频生成 AI 咖啡报告</button>
          </div>
        </div>
        <div style="font-size:11.5px; color:var(--text-muted); margin-top:4px;">当前流地址: <code>${safeActiveUrl}</code></div>
        <video controls preload="metadata" src="${safeActiveUrl}"></video>
        ${fileListHtml ? `<div style="margin-top:10px;"><div style="font-size:12px; color:var(--crema-bright); margin-bottom:4px;">📂 相机 DCIM 远程文件列表:</div>${fileListHtml}</div>` : ''}
      </div>
    `;
    showToast('🎬 已加载相机 :8088 最新录制视频预览');
  } catch (err) {
    container.innerHTML = `<div class="media-preview-drawer" style="color:var(--accent-red); font-size:12px;">拉取相机媒体信息失败: ${escapeHtml(err)}</div>`;
  }
}

async function triggerMediaWebhook(deviceId, mediaUrl) {
  const res = await fetch('/api/camera/webhook', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      device_id: deviceId,
      media_url: mediaUrl
    })
  });
  const data = await res.json();
  if (data.ok && data.record) {
    currentRecordId = data.record.id;
    await fetchState();
    switchTab('reports');
    showToast(`☕️ 已通过相机 :8088 视频 (${mediaUrl.split('/').pop()}) 生成萃取报告！`);
  }
}

function renderNotifyTab() {
  const cfg = appState.notification_config || {};
  document.getElementById('cfgMobileUrl').value = cfg.mobile_base_url || 'http://192.168.5.84:8788';
  document.getElementById('cfgWecomUrl').value = cfg.wecom_webhook_url || '';
  document.getElementById('cfgServerChan').value = cfg.serverchan_sendkey || '';
  document.getElementById('cfgBarkUrl').value = cfg.bark_url || '';

  const list = appState.notifications || [];
  document.getElementById('notificationList').innerHTML = list.map(n => `
    <div class="record-item" data-record-id="${escapeHtml(n.record_id || '')}" onclick="openRecordFromNotif(this.dataset.recordId)">
      <div class="record-item-top">
        <span class="badge ${n.level === 'warning' ? 'badge-warn' : 'badge-ok'}">${escapeHtml(n.title)}</span>
        <span style="font-size:11px; color:var(--text-muted);">${escapeHtml(n.time)}</span>
      </div>
      <pre style="white-space:pre-wrap; font-size:12px; color:var(--text-main); margin:6px 0;">${escapeHtml(n.summary)}</pre>
      <div class="record-meta">
        <span>推送渠道: ${escapeHtml((n.channels || []).join(' / '))}</span>
        <span style="color:var(--crema-bright);">点击查看/补全 →</span>
      </div>
    </div>
  `).join('');
}

function openRecordFromNotif(recordId) {
  currentRecordId = recordId;
  switchTab('reports');
  renderAll();
}


async function provisionCameraSta() {
  const body = {
    device_id: document.getElementById('staDeviceId').value.trim(),
    ssid: document.getElementById('staSsid').value.trim(),
    password: document.getElementById('staPassword').value,
    lan_ip: document.getElementById('staLanIp').value.trim(),
  };
  await fetch('/api/camera/provision_sta', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  });
  await fetchState();
  showToast('📡 已下发 DUML [07:47] STA 配网指令并部署相机内部守护进程！');
}

async function execCameraCmd(cmd) {
  const deviceId = document.getElementById('staDeviceId').value.trim() || 'pocket4p';
  await fetch('/api/camera/exec', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ device_id: deviceId, cmd })
  });
  await fetchState();
  showToast(`已在 ${deviceId} 内部执行: ${cmd}`);
}

async function execCustomCameraCmd() {
  const cmd = document.getElementById('customShellInput').value.trim();
  if (cmd) await execCameraCmd(cmd);
}

async function triggerCameraShutter(deviceId, action) {
  await fetch('/api/camera/shutter', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ device_id: deviceId, action })
  });
  await fetchState();
  showToast(action === 'start' ? `🔴 已通过局域网触发 ${deviceId} 开始录制` : `⏹️ 已通过局域网停止 ${deviceId} 录制`);
}

async function saveNotifyConfig() {
  const body = {
    mobile_base_url: document.getElementById('cfgMobileUrl').value.trim(),
    wecom_webhook_url: document.getElementById('cfgWecomUrl').value.trim(),
    serverchan_sendkey: document.getElementById('cfgServerChan').value.trim(),
    bark_url: document.getElementById('cfgBarkUrl').value.trim(),
  };
  await fetch('/api/notifications/config', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  });
  await fetchState();
  showToast('💾 手机通知渠道配置已保存');
}

