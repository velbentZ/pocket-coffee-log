// Core app state, report rendering, radar comparison & voice controls
let appState = null;
let currentRecordId = null;

let _toastTimer = null;
let _lastToastMsg = '';

function showToast(msg) {
  const t = document.getElementById('toast');
  if (!t) return;
  clearTimeout(_toastTimer);
  let announcement = String(msg || '');
  if (announcement && announcement === _lastToastMsg) {
    announcement += '\u00A0';
  }
  _lastToastMsg = announcement;
  t.textContent = '';
  t.classList.add('is-visible');
  requestAnimationFrame(() => { t.textContent = announcement; });
  _toastTimer = setTimeout(() => {
    t.classList.remove('is-visible');
    t.textContent = '';
  }, 3200);
}

function switchTab(tabName) {
  document.querySelectorAll('.tab-panel').forEach(el => el.classList.remove('active'));
  document.querySelectorAll('.nav-tab').forEach(el => {
    el.classList.toggle('active', el.dataset.tab === tabName);
  });
  const panel = document.getElementById('tab-' + tabName);
  if (panel) panel.classList.add('active');
}

async function fetchState() {
  const res = await fetch('/api/state');
  appState = await res.json();
  if (!currentRecordId && appState.records.length > 0) {
    currentRecordId = appState.records[0].id;
  }
  renderAll();
}

function renderAll() {
  if (!appState) return;
  renderVoiceHeader();
  renderRecordList();
  renderSelectedReport();
  renderBeansTab();
  renderCameraTab();
  renderNotifyTab();
}

function renderVoiceHeader() {
  const vs = appState.voice_session || {};
  const pill = document.getElementById('voicePill');
  const pillText = document.getElementById('voicePillText');
  const desc = document.getElementById('voiceEventDesc');

  if (vs.state === 'recording') {
    pill.className = 'pill recording';
    pillText.textContent = `🔴 正在录制 (${vs.camera_model}) · 等待「制作完成」`;
  } else {
    pill.className = 'pill';
    pillText.textContent = '语音唤醒待命：「我要开始制作咖啡」';
  }
  desc.textContent = vs.last_event || '';
}

function renderRecordList() {
  const listEl = document.getElementById('recordList');
  document.getElementById('recordCountBadge').textContent = `${appState.records.length} 条记录`;
  listEl.innerHTML = appState.records.map(r => {
    const isSelected = r.id === currentRecordId;
    const isEquip = r.record_type === 'equipment_profile';
    const badgeHtml = isEquip
      ? `<span class="badge badge-ok" style="background:rgba(212,163,115,0.22); color:var(--crema-bright);">⚙️ 常驻设备档案</span>`
      : (r.status === 'needs_info'
        ? `<span class="badge badge-warn">⚠️ 待补全 (${r.missing_fields.length})</span>`
        : `<span class="badge badge-ok">✓ 完整报告</span>`);
    const metaLeft = isEquip
      ? `🛠️ 已收录 ${(r.equipment_items || []).length || 8} 项常驻器具`
      : `${r.bean_weight_g || '--'}g → ${r.yield_g || '--'}g (${r.brew_ratio || '--'})`;
    return `
      <div class="record-item ${isSelected ? 'active' : ''}" data-record-id="${escapeHtml(r.id)}" onclick="selectRecord(this.dataset.recordId)">
        <div class="record-item-top">
          <span style="font-size:11.5px; color:var(--crema); font-weight:600;">${escapeHtml(r.brew_method || (isEquip ? '常驻设备与器具补充' : '意式浓缩'))}</span>
          ${badgeHtml}
        </div>
        <div class="record-bean">${escapeHtml(r.bean_name || '未命名咖啡豆')}</div>
        <div class="record-meta">
          <span>${escapeHtml(metaLeft)}</span>
          <span>${escapeHtml(String(r.created_at || '').slice(5, 16))}</span>
        </div>
      </div>
    `;
  }).join('');
}

function selectRecord(id) {
  currentRecordId = id;
  renderRecordList();
  renderSelectedReport();
}

function buildRadarSvg(fp) {
  const keys = [
    { k: 'acidity', label: '酸质' },
    { k: 'sweetness', label: '甜感' },
    { k: 'body', label: '醇厚度' },
    { k: 'aroma', label: '香气' },
    { k: 'aftertaste', label: '余韵' },
    { k: 'balance', label: '平衡感' }
  ];
  const cx = 120, cy = 115, maxR = 76;
  const angleStep = (Math.PI * 2) / keys.length;

  let gridPolys = '';
  [0.35, 0.68, 1.0].forEach(level => {
    const pts = keys.map((_, i) => {
      const a = -Math.PI / 2 + i * angleStep;
      return `${(cx + Math.cos(a) * maxR * level).toFixed(1)},${(cy + Math.sin(a) * maxR * level).toFixed(1)}`;
    }).join(' ');
    gridPolys += `<polygon points="${pts}" fill="none" stroke="rgba(212,163,115,0.22)" stroke-width="1"/>`;
  });

  const dataPts = keys.map((item, i) => {
    const val = Math.min(10, Math.max(1, Number(fp[item.k] || 7.5))) / 10.0;
    const a = -Math.PI / 2 + i * angleStep;
    return `${(cx + Math.cos(a) * maxR * val).toFixed(1)},${(cy + Math.sin(a) * maxR * val).toFixed(1)}`;
  }).join(' ');

  const labelsSvg = keys.map((item, i) => {
    const a = -Math.PI / 2 + i * angleStep;
    const lx = cx + Math.cos(a) * (maxR + 24);
    const ly = cy + Math.sin(a) * (maxR + 18);
    const score = Number(fp[item.k] || 7.5).toFixed(1);
    return `<text x="${lx.toFixed(1)}" y="${ly.toFixed(1)}" fill="#faedcd" font-size="11" font-weight="600" text-anchor="middle" dominant-baseline="middle">${item.label} ${score}</text>`;
  }).join('');

  return `
    <svg width="245" height="230" viewBox="0 0 245 230">
      ${gridPolys}
      <polygon points="${dataPts}" fill="rgba(212, 163, 115, 0.35)" stroke="#f3c68f" stroke-width="2.2" />
      ${labelsSvg}
    </svg>
  `;
}

function renderSelectedReport() {
  const container = document.getElementById('reportDetailArea');
  const rec = appState.records.find(r => r.id === currentRecordId) || appState.records[0];
  if (!rec) {
    container.innerHTML = '<div class="report-card">暂无记录</div>';
    return;
  }
  renderMainReport(rec);
}

function toggleReportVideoPlayer(recordId, mediaUrl, mediaKind = 'video') {
  const drawer = document.getElementById(`reportVideoDrawer_${recordId}`);
  const cleanUrl = sanitizeMediaUrl(mediaUrl);
  if (!drawer || !cleanUrl) return;
  if (drawer.innerHTML.trim()) {
    drawer.innerHTML = '';
    return;
  }
  const safeUrl = escapeHtml(cleanUrl);
  const safeId = escapeHtml(recordId);
  const safeKind = mediaKind === 'audio' ? 'audio' : 'video';
  const isAudio = safeKind === 'audio' || /\.(m4a|wav|mp3|aac|caf|ogg|flac)(?:$|[?#])/i.test(cleanUrl);
  const heading = isAudio ? '🎙️ 原始语音素材回放' : '🎬 原始视频素材回放';
  const playerTag = isAudio
    ? `<audio controls autoplay preload="metadata" src="${safeUrl}" style="width:100%; margin-top:10px;"></audio>`
    : `<video controls autoplay preload="metadata" src="${safeUrl}"></video>`;
  drawer.innerHTML = `
    <div class="report-video-drawer">
      <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:8px;">
        <strong style="font-size:13px; color:#74c69d;">${heading} (${safeUrl})</strong>
        <div style="display:flex; gap:8px;">
          <a class="btn" style="padding:5px 10px; font-size:12px; text-decoration:none;" href="${safeUrl}" target="_blank" rel="noopener noreferrer">🔗 在新窗口打开 / 下载</a>
          <button class="btn" type="button" style="padding:5px 10px; font-size:12px;" data-record-id="${safeId}" data-media-url="${safeUrl}" data-media-kind="${safeKind}" onclick="toggleReportVideoPlayer(this.dataset.recordId, this.dataset.mediaUrl, this.dataset.mediaKind)">✖ 收起播放器</button>
        </div>
      </div>
      ${playerTag}
    </div>
  `;
}


function renderMainReport(rec) {
  const container = document.getElementById('reportDetailArea');
  if (!container || !rec) return;

  const isEquip = rec.record_type === 'equipment_profile';
  const missingSet = new Set((rec.missing_fields || []).map(m => m.field));
  const isColdBrew = (rec.brew_method || '').includes('冷萃');
  const timeFormatted = rec.extraction_time_s
    ? (isColdBrew && rec.extraction_time_s >= 3600 ? `${(rec.extraction_time_s / 3600).toFixed(1)} 小时` : `${rec.extraction_time_s} 秒`)
    : '⚠️ 待补全';

  const safeRecId = escapeHtml(rec.id);
  let missingBannerHtml = '';
  if (!isEquip && rec.status === 'needs_info' && rec.missing_fields.length > 0) {
    const inputsHtml = rec.missing_fields.map(m => `
      <div class="supp-field">
        <label>${escapeHtml(m.label)}</label>
        <input id="supp_${escapeHtml(m.field)}" placeholder="请输入 ${escapeHtml(m.label)}" />
      </div>
    `).join('');

    missingBannerHtml = `
      <div class="missing-banner">
        <h3>📲 手机端提醒：检测到本杯记录缺少 ${rec.missing_fields.length} 项核心参数，请补充</h3>
        <p>相机已捕获您的主要制作过程，但未听清 <strong>${escapeHtml(rec.missing_fields.map(m => m.label).join('、'))}</strong>。您可以直接填写下方输入框或用一句话补充，报告与小红书文案将立即重算更新：</p>
        <div class="supplement-grid">${inputsHtml}</div>
        <div class="voice-input-group" style="margin-top:8px;">
          <input id="suppVoiceText" class="voice-input" placeholder="或者直接一句话语音补充，例如：研磨度是刻度 12 格，萃取压力 9 bar" />
          <button class="btn btn-primary" type="button" data-record-id="${safeRecId}" onclick="submitSupplement(this.dataset.recordId)">✨ 提交补全并重新生成完整报告</button>
        </div>
      </div>
    `;
  }

  const flavorTagsHtml = (rec.flavor_notes || []).map(t => `<span class="flavor-tag">✨ ${escapeHtml(t)}</span>`).join('');
  const suggestionsHtml = (rec.suggestions || []).map(s => `<li>${escapeHtml(s)}</li>`).join('');
  const timelineHtml = (rec.timeline_events || []).map(ev => `
    <div class="t-step">
      <div class="t-time">${escapeHtml(ev.timestamp)}</div>
      <div class="t-stage">${escapeHtml(ev.stage)}</div>
      <div class="t-desc">${escapeHtml(ev.detail)}</div>
    </div>
  `).join('');

  const cleanRecMediaUrl = sanitizeMediaUrl(rec.media_url);
  const isAudioRec = rec.media_kind === 'audio' || /\.(m4a|wav|mp3|aac|caf|ogg|flac)(?:$|[?#])/i.test(cleanRecMediaUrl || '');
  const playVideoBtnHtml = cleanRecMediaUrl
    ? `<div style="margin-top:8px;"><button class="btn btn-primary" type="button" style="padding:6px 12px; font-size:12px;" data-record-id="${safeRecId}" data-media-url="${escapeHtml(cleanRecMediaUrl)}" data-media-kind="${isAudioRec ? 'audio' : 'video'}" onclick="toggleReportVideoPlayer(this.dataset.recordId, this.dataset.mediaUrl, this.dataset.mediaKind)">${isAudioRec ? '🎙️ 播放原始语音素材' : '🎬 播放原始视频素材'}</button></div>`
    : '';

  let keyframeGalleryHtml = '';
  if (rec.keyframes && rec.keyframes.length > 0) {
    const presetBadgeMap = isEquip
      ? {
          scale_dose: 'E1 压粉与布粉台',
          grinder_dial: 'E2 配件与吸尘器',
          espresso_gauge: 'E3 咖啡机与手柄',
          final_cup: 'E4 咖啡角与常驻豆',
          reset_center: 'E0 咖啡角全景'
        }
      : {
          scale_dose: 'P1 称豆',
          grinder_dial: 'P2 刻度',
          espresso_gauge: 'P3 压力表',
          final_cup: 'P4 出杯',
          reset_center: 'P0 回中'
        };
    const fallbackPresets = isEquip
      ? ['E1 压粉与布粉台', 'E2 配件与吸尘器', 'E3 咖啡机与手柄', 'E4 咖啡角与常驻豆']
      : ['P1 称豆', 'P2 刻度', 'P3 压力表', 'P4 出杯'];
    const fallbackPcts = [15, 35, 70, 90];
    const extractedTotal = rec.keyframes.filter(kf => kf && kf.extracted && kf.image_path).length;

    const kfCards = rec.keyframes.map((kf, idx) => {
      const pct = kf.percentage || fallbackPcts[idx] || 0;
      const ts = kf.timestamp_s ?? '--';
      const presetTag = kf.preset_badge || presetBadgeMap[kf.gimbal_preset] || fallbackPresets[idx] || '关键帧';
      const stageTitle = kf.frame_stage || kf.stage || presetTag;
      const detectedObj = kf.detected_fields || {};
      const detectedEntries = Object.entries(detectedObj).filter(([, v]) => v !== null && v !== undefined && v !== '');
      const detectedHtml = detectedEntries.length > 0
        ? `<div class="kf-detected-badge">🔍 识别: ${escapeHtml(detectedEntries.map(([k, v]) => `${k}=${v}`).join(', '))}</div>`
        : '';

      const visualBody = (kf.extracted && kf.image_path)
        ? `<img class="report-keyframe-img" data-record-id="${escapeHtml(rec.id)}" data-stage-label="${escapeHtml(presetTag)} (${pct}%)" src="/api/media/keyframe?path=${encodeURIComponent(kf.image_path)}" alt="${escapeHtml(stageTitle)}" width="640" height="360" loading="lazy" crossorigin="anonymous" />`
        : `<div class="report-keyframe-placeholder"><strong style="color:var(--crema);">⏱️ 画面锚点 t=${escapeHtml(ts)}s</strong><span>${escapeHtml(kf.visual_description || stageTitle)}</span></div>`;

      return `
        <div class="keyframe-card">
          <div style="display:flex; justify-content:space-between; align-items:center; gap:4px;">
            <span class="badge badge-ok" style="padding:2px 7px;">${escapeHtml(presetTag)}</span>
            <span style="color:var(--crema-bright); font-weight:700; font-family:monospace;">${escapeHtml(pct)}% · t=${escapeHtml(ts)}s</span>
          </div>
          <div style="color:var(--latte); font-weight:600; margin-top:5px;">${escapeHtml(stageTitle)}</div>
          ${visualBody}
          ${detectedHtml}
        </div>
      `;
    }).join('');

    const galleryHeading = isEquip
      ? '🖼️ 居家咖啡角设备与器具实拍画廊 (E1 压粉布粉 / E2 吧台配件 / E3 咖啡机手柄 / E4 咖啡角与常驻豆)'
      : '🖼️ 相机 4 阶段视觉抽帧画廊 (P1 称豆 / P2 刻度 / P3 压力表 / P4 出杯)';

    keyframeGalleryHtml = `
      <div class="report-keyframe-box">
        <div class="report-keyframe-head">
          <h4>${galleryHeading}</h4>
          <span class="badge ${extractedTotal > 0 ? 'badge-ok' : 'badge-warn'}">
            ${extractedTotal > 0 ? `✓ 已落盘 ${extractedTotal}/4 张实拍关键帧缩略图` : '📹 4 阶段多模态时间戳锚点已关联'}
          </span>
        </div>
        <div class="keyframe-grid">${kfCards}</div>
      </div>
    `;
  }

  let coreMetricsOrEquipmentHtml = '';
  let middleAnalysisRowHtml = '';

  if (isEquip) {
    const eqItems = rec.equipment_items || [];
    const eqCardsHtml = eqItems.map(it => `
      <div class="metric-box" style="border-color:rgba(212,163,115,0.36);">
        <div class="metric-label"><span>${escapeHtml(it.category || '常驻设备/器具')}</span><span>🛠️</span></div>
        <div class="metric-val" style="font-size:15px; line-height:1.35;">${escapeHtml(it.name)}</div>
        <div class="metric-sub" style="margin-top:4px; color:var(--crema);">${escapeHtml(it.spec || '')}</div>
        <div class="metric-sub" style="margin-top:2px;">${escapeHtml(it.role || '')}</div>
      </div>
    `).join('');

    coreMetricsOrEquipmentHtml = `
      <div class="missing-banner" style="border-color:var(--accent-green); background:rgba(82,183,136,0.10); margin-bottom:18px;">
        <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:10px;">
          <div>
            <h3 style="color:#74c69d;">⚙️ 已智能识别为「常驻设备与器具介绍」· 自动同步至常驻设备库</h3>
            <p style="margin:4px 0 0 0;">系统检测到本次视频为居家咖啡机与制作工具盘点（未进行实际浓缩萃取），已拒绝生成虚假的萃取参数报告，并将您口述的 <strong>${eqItems.length} 项设备与器具</strong>自动写入您的常驻设备档案。</p>
          </div>
          <button class="btn btn-primary" type="button" onclick="switchTab('beans')">🫘 查看常驻设备与豆仓档案 →</button>
        </div>
      </div>

      <div class="metrics-grid">
        ${eqCardsHtml}
      </div>
    `;

    middleAnalysisRowHtml = `
      <div class="diagnosis-box" style="margin-bottom:22px;">
        <h4>⚙️ 常驻咖啡角设备盘点摘要 &amp; 动线配合建议</h4>
        <div class="diagnosis-text">${escapeHtml(rec.extraction_diagnosis || '')}</div>
        <ul class="suggestion-list">${suggestionsHtml}</ul>
        <div style="margin-top:12px; padding:10px 14px; background:rgba(0,0,0,0.28); border-radius:10px; font-size:12.5px; color:var(--latte);">
          <strong style="color:var(--crema-bright);">🎙️ 原始口述语音归档：</strong>「${escapeHtml(rec.transcript || '')}」
        </div>
      </div>
    `;
  } else {
    coreMetricsOrEquipmentHtml = `
      <!-- 8 Core Metrics Requested by User -->
      <div class="metrics-grid">
        <div class="metric-box ${missingSet.has('brew_method') ? 'missing' : ''}">
          <div class="metric-label"><span>制作方式 (意式/冷萃)</span><span>☕️</span></div>
          <div class="metric-val">${escapeHtml(rec.brew_method || '⚠️ 待补全')}</div>
          <div class="metric-sub">水温: ${rec.water_temp_c ? escapeHtml(rec.water_temp_c) + '°C' : (isColdBrew ? '4°C 冷藏慢萃' : '93°C 恒温')}</div>
        </div>

        <div class="metric-box ${missingSet.has('bean_weight_g') ? 'missing' : ''}">
          <div class="metric-label"><span>咖啡豆称重 (粉量)</span><span>⚖️</span></div>
          <div class="metric-val">${rec.bean_weight_g ? escapeHtml(rec.bean_weight_g) + ' g' : '⚠️ 待补全'}</div>
          <div class="metric-sub">单品豆精准称量</div>
        </div>

        <div class="metric-box ${missingSet.has('grinder_type') ? 'missing' : ''}">
          <div class="metric-label"><span>研磨机器类型</span><span>⚙️</span></div>
          <div class="metric-val" style="font-size:15.5px;">${escapeHtml(rec.grinder_type || '⚠️ 待补全')}</div>
          <div class="metric-sub">${escapeHtml(rec.grinder_model || '磨豆机型号待确认')}</div>
        </div>

        <div class="metric-box ${missingSet.has('grind_setting') ? 'missing' : ''}">
          <div class="metric-label"><span>研磨度刻度</span><span>🎯</span></div>
          <div class="metric-val">${escapeHtml(rec.grind_setting || '⚠️ 待补全')}</div>
          <div class="metric-sub">${rec.grinder_type === '额外独立磨豆机' ? '外置独立单品刀盘' : '内置一体锥刀/平刀'}</div>
        </div>

        <div class="metric-box ${missingSet.has('yield_g') ? 'missing' : ''}">
          <div class="metric-label"><span>萃取液重 / 出液量</span><span>💧</span></div>
          <div class="metric-val">${rec.yield_g ? escapeHtml(rec.yield_g) + (isColdBrew ? ' ml' : ' g') : '⚠️ 待补全'}</div>
          <div class="metric-sub">粉液比: <strong>${escapeHtml(rec.brew_ratio || '--')}</strong></div>
        </div>

        <div class="metric-box ${missingSet.has('extraction_time_s') ? 'missing' : ''}">
          <div class="metric-label"><span>萃取时间</span><span>⏱️</span></div>
          <div class="metric-val">${escapeHtml(timeFormatted)}</div>
          <div class="metric-sub">${isColdBrew ? '低温慢速浸泡' : '含预浸泡读秒'}</div>
        </div>

        <div class="metric-box ${missingSet.has('pressure_bar') ? 'missing' : ''}">
          <div class="metric-label"><span>萃取压力</span><span>🧭</span></div>
          <div class="metric-val">${rec.pressure_bar !== null && rec.pressure_bar !== undefined ? escapeHtml(rec.pressure_bar) + ' bar' : '⚠️ 待补全'}</div>
          <div class="metric-sub">${isColdBrew ? '常压浸泡萃取' : '黄金泵压区间 8.5-9.5 bar'}</div>
        </div>

        <div class="metric-box">
          <div class="metric-label"><span>原始语音识别摘录</span><span>🎙️</span></div>
          <div style="font-size:12px; color:var(--latte); line-height:1.4; max-height:54px; overflow-y:auto;">
            「${escapeHtml(rec.transcript || '无语音文本')}」
          </div>
        </div>
      </div>
    `;

    middleAnalysisRowHtml = `
      <!-- Radar Chart + AI Barista Diagnosis & Next-Brew Suggestions -->
      <div class="analysis-row">
        <div class="radar-box">
          <h4>📊 感官风味六维雷达</h4>
          ${buildRadarSvg(rec.flavor_profile || {})}
        </div>

        <div class="diagnosis-box">
          <h4>🧠 AI 咖啡师萃取诊断 &amp; 下次优化建议</h4>
          <div class="diagnosis-text">${escapeHtml(rec.extraction_diagnosis || '')}</div>
          <ul class="suggestion-list">${suggestionsHtml}</ul>

          <div style="margin-top:16px; padding-top:12px; border-top:1px dashed var(--border-subtle);">
            <div style="font-size:12.5px; color:var(--crema-bright); font-weight:600; margin-bottom:8px;">
              👅 喝完觉得味道如何？（点击反馈主观品鉴，AI 将自动校准下次磨豆刻度并锁定黄金配方）：
            </div>
            <div style="display:flex; gap:8px; flex-wrap:wrap;">
              <button class="btn" type="button" data-record-id="${safeRecId}" onclick="submitTasteFeedback(this.dataset.recordId, 5, 'balanced_sweet')">🏆 酸甜平衡·锁定黄金配方 (5★)</button>
              <button class="btn" type="button" data-record-id="${safeRecId}" onclick="submitTasteFeedback(this.dataset.recordId, 4, 'too_sour')">🍋 偏酸/尖酸 (下次调细刻度)</button>
              <button class="btn" type="button" data-record-id="${safeRecId}" onclick="submitTasteFeedback(this.dataset.recordId, 3, 'too_bitter')">🍫 偏苦/尾段涩 (下次调粗/提前截流)</button>
              <button class="btn" type="button" data-record-id="${safeRecId}" onclick="submitTasteFeedback(this.dataset.recordId, 4, 'watery')">💧 偏淡/醇厚不足 (下次加粉收紧比例)</button>
            </div>
          </div>
        </div>
      </div>
    `;
  }

  const posterGridCellsHtml = isEquip
    ? (rec.equipment_items || []).slice(0, 6).map(it => `
        <div class="xhs-cell"><span>${escapeHtml(it.category || '常驻装备')}</span><strong>${escapeHtml((it.name || '').slice(0, 14))}</strong></div>
      `).join('')
    : `
        <div class="xhs-cell"><span>咖啡豆称重</span><strong>${escapeHtml(rec.bean_weight_g || '--')} g</strong></div>
        <div class="xhs-cell"><span>出液量 / 粉液比</span><strong>${escapeHtml(rec.yield_g || '--')}g (${escapeHtml(rec.brew_ratio || '--')})</strong></div>
        <div class="xhs-cell"><span>磨豆设备</span><strong>${escapeHtml(rec.grinder_type || '--')}</strong></div>
        <div class="xhs-cell"><span>研磨刻度</span><strong>${escapeHtml(rec.grind_setting || '--')}</strong></div>
        <div class="xhs-cell"><span>萃取时间</span><strong>${escapeHtml(timeFormatted)}</strong></div>
        <div class="xhs-cell"><span>萃取压力</span><strong>${escapeHtml(rec.pressure_bar || '--')} bar</strong></div>
      `;

  const jikeWeiboText = buildJikeWeiboCopy(rec);
  const markdownText = buildMarkdownCopy(rec);

  container.innerHTML = `
    ${missingBannerHtml}

    <div class="report-card">
      <div class="report-header">
        <div class="report-title-block">
          <div class="eyebrow">📹 ${escapeHtml(rec.camera_device)} (LAN STA 自动录制) · ${escapeHtml(rec.created_at)}</div>
          <h2>${escapeHtml(rec.bean_name || '待确认咖啡豆')} ${rec.bean_roast ? `<span style="font-size:15px; color:var(--crema); font-weight:600;">· ${escapeHtml(rec.bean_roast)}</span>` : ''}</h2>
          <div class="flavor-tags">${flavorTagsHtml}</div>
        </div>
        <div style="text-align:right;">
          <span class="badge ${isEquip || rec.status === 'complete' ? 'badge-ok' : 'badge-warn'}" style="font-size:13px; padding:6px 12px;">
            ${isEquip ? '⚙️ 常驻设备与器具建档完成' : (rec.status === 'complete' ? '✓ 参数完整 · AI 复盘已生成' : '⚠️ 待补充缺失参数')}
          </span>
          <div style="font-size:11.5px; color:var(--text-muted); margin-top:6px;">视频源: <code>${escapeHtml(rec.video_path || 'LAN Stream')}</code></div>
          ${playVideoBtnHtml}
        </div>
      </div>

      <div id="reportVideoDrawer_${safeRecId}"></div>

      ${coreMetricsOrEquipmentHtml}

      ${keyframeGalleryHtml}

      ${middleAnalysisRowHtml}

      <!-- Video & Audio Recognition Timeline -->
      <div class="timeline-box">
        <h4>🎬 ${escapeHtml(rec.camera_device)} 视频画面 &amp; 语音多模态时间轴</h4>
        <div class="timeline-steps">${timelineHtml}</div>
      </div>

      ${isEquip ? '' : `
      <!-- Beanconqueror / Visualizer.coffee Inspired Side-by-Side Shot Comparison -->
      <div class="visualizer-box" id="shotVisualizerSection">
        <div class="visualizer-header">
          <h4>📊 同款豆萃取对比 (Visualizer 视图)</h4>
          <span class="badge badge-ok">正在加载历史出品对比...</span>
        </div>
      </div>
      `}

      <!-- Multi-Platform Quick Social Share Hub -->
      <div class="timeline-box" style="border-color:rgba(243,198,143,0.38); background:linear-gradient(145deg, rgba(45,30,23,0.75), rgba(18,13,10,0.9));">
        <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:10px; margin-bottom:12px;">
          <div>
            <h4 style="margin-bottom:2px;">🚀 多平台一键快速分享中枢 (海报剪贴板直贴 + 原生 AirDrop/微信/小红书/即刻/Notion)</h4>
            <div style="font-size:12px; color:var(--text-muted);">支持一键将 <strong>3:4 高清实拍拼图海报直接复制到系统剪贴板</strong>（打开微信/小红书网页端直接 <code>Cmd+V</code> 粘贴图片），或调起 macOS/iOS 系统原生分享面板！</div>
          </div>
          <div style="display:flex; gap:8px; flex-wrap:wrap;">
            <button class="btn btn-primary" type="button" data-record-id="${safeRecId}" onclick="copyPosterImageToClipboard(this.dataset.recordId)">📋 一键复制海报图片到剪贴板 (直接 Cmd+V 粘贴)</button>
            <button class="btn" type="button" data-record-id="${safeRecId}" onclick="exportPosterImage(this.dataset.recordId)">💾 下载 3:4 高清长图海报 (.png)</button>
            <button class="btn" type="button" data-record-id="${safeRecId}" onclick="nativeSystemShare(this.dataset.recordId)">📤 系统原生分享 (AirDrop / 微信 / 备忘录)</button>
          </div>
        </div>

        <div style="display:flex; gap:8px; flex-wrap:wrap; padding-top:8px; border-top:1px dashed rgba(212,163,115,0.22);">
          <button class="btn" type="button" style="border-color:rgba(255,117,143,0.45); color:#ffb3c1;" data-record-id="${safeRecId}" onclick="quickSharePlatform(this.dataset.recordId, 'xiaohongshu')">📕 一键复制海报+文案并打开小红书发布</button>
          <button class="btn" type="button" style="border-color:rgba(116,198,157,0.45); color:#74c69d;" data-record-id="${safeRecId}" onclick="quickSharePlatform(this.dataset.recordId, 'wechat')">💬 一键复制微信海报+打卡文案</button>
          <button class="btn" type="button" style="border-color:rgba(244,162,97,0.45); color:#f4a261;" data-record-id="${safeRecId}" onclick="quickSharePlatform(this.dataset.recordId, 'weibo')">🔥 一键复制短图文并跳转微博/即刻</button>
          <button class="btn" type="button" data-record-id="${safeRecId}" onclick="quickSharePlatform(this.dataset.recordId, 'markdown')">📝 一键复制 Notion / Markdown 表格档案</button>
        </div>
      </div>

      <!-- Social Media Share Studio (Xiaohongshu & WeChat & Multi-Platform Templates) -->
      <div class="share-studio">
        <div class="xhs-poster" id="posterCard">
          <div>
            <div class="xhs-poster-badge">${isEquip ? '⚙️ POCKET COFFEE STUDIO · 咖啡角装备档案' : '☕️ POCKET COFFEE STUDIO · 每日咖啡打卡'}</div>
            <div class="xhs-poster-title">${escapeHtml(rec.bean_name || '今日私藏咖啡豆')}</div>
            <div style="font-size:12px; color:var(--crema); margin-top:4px;">${escapeHtml(rec.brew_method || '意式浓缩')} · ${escapeHtml(rec.camera_device)} 全自动记录</div>

            <div class="xhs-poster-grid">
              ${posterGridCellsHtml}
            </div>

            <div style="font-size:12px; color:#f5ebe6; background:rgba(212,163,115,0.12); padding:10px 12px; border-radius:10px;">
              <strong style="color:var(--crema-bright);">💡 ${isEquip ? '咖啡角配置亮点：' : '咖啡师笔记：'}</strong>
              ${escapeHtml((rec.suggestions && rec.suggestions[0]) ? rec.suggestions[0] : (rec.extraction_diagnosis || ''))}
            </div>
          </div>

          <div class="xhs-poster-footer">
            <span>🎯 标签: ${escapeHtml((rec.flavor_notes || []).slice(0, 4).join(' / '))}</span>
            <span>${escapeHtml(String(rec.created_at || '').slice(0, 10))}</span>
          </div>
        </div>

        <div class="copy-box">
          <div class="copy-card">
            <div class="copy-card-header">
              <strong style="font-size:13.5px; color:#ff758f;">📕 小红书种草图文笔记 (含热门标签)</strong>
              <div style="display:flex; gap:6px; flex-wrap:wrap;">
                <button class="btn" type="button" onclick="copyTextValue('xhsCopyArea', '已复制小红书爆款文案！')">📋 仅复制文案</button>
                <button class="btn btn-primary" type="button" data-record-id="${safeRecId}" onclick="quickSharePlatform(this.dataset.recordId, 'xiaohongshu')">🚀 复制文案+海报去小红书发布</button>
              </div>
            </div>
            <textarea id="xhsCopyArea" readonly>${escapeHtml(rec.xiaohongshu_copy || '')}</textarea>
          </div>

          <div class="copy-card">
            <div class="copy-card-header">
              <strong style="font-size:13.5px; color:#74c69d;">💬 微信朋友圈 / 咖啡社群打卡文案</strong>
              <div style="display:flex; gap:6px; flex-wrap:wrap;">
                <button class="btn" type="button" data-record-id="${safeRecId}" onclick="copyPosterImageToClipboard(this.dataset.recordId)">🖼️ 复制海报图 (微信直接粘贴)</button>
                <button class="btn btn-primary" type="button" onclick="copyTextValue('wxCopyArea', '已复制微信朋友圈文案！')">📋 复制微信文案</button>
              </div>
            </div>
            <textarea id="wxCopyArea" style="min-height:78px;" readonly>${escapeHtml(rec.wechat_copy || '')}</textarea>
          </div>

          <div class="copy-card">
            <div class="copy-card-header">
              <strong style="font-size:13.5px; color:#f4a261;">⚡ 即刻 / 微博 / Notion Markdown 极速导出</strong>
              <div style="display:flex; gap:6px; flex-wrap:wrap;">
                <button class="btn" type="button" onclick="copyTextValue('jikeCopyArea', '已复制即刻/微博短图文文案！')">📋 复制即刻/微博文案</button>
                <button class="btn" type="button" onclick="copyTextValue('mdCopyArea', '已复制 Notion / Markdown 档案表格！')">📝 复制 Markdown 表格</button>
              </div>
            </div>
            <textarea id="jikeCopyArea" style="min-height:66px;" readonly>${escapeHtml(jikeWeiboText)}</textarea>
            <textarea id="mdCopyArea" style="display:none;" readonly>${escapeHtml(markdownText)}</textarea>
          </div>
        </div>
      </div>
    </div>
  `;

  if (!isEquip) {
    loadShotComparison(rec);
  }
}

function buildDualRadarSvg(baseFp, latestFp) {
  const keys = [
    { k: 'acidity', label: '酸质' },
    { k: 'sweetness', label: '甜感' },
    { k: 'body', label: '醇厚度' },
    { k: 'aroma', label: '香气' },
    { k: 'aftertaste', label: '余韵' },
    { k: 'balance', label: '平衡感' }
  ];
  const cx = 122, cy = 115, maxR = 74;
  const angleStep = (Math.PI * 2) / keys.length;

  let gridPolys = '';
  [0.35, 0.68, 1.0].forEach(level => {
    const pts = keys.map((_, i) => {
      const a = -Math.PI / 2 + i * angleStep;
      return `${(cx + Math.cos(a) * maxR * level).toFixed(1)},${(cy + Math.sin(a) * maxR * level).toFixed(1)}`;
    }).join(' ');
    gridPolys += `<polygon points="${pts}" fill="none" stroke="rgba(212,163,115,0.2)" stroke-width="1"/>`;
  });

  const makePts = (fp) => keys.map((item, i) => {
    const val = Math.min(10, Math.max(1, Number((fp && fp[item.k]) || 7.5))) / 10.0;
    const a = -Math.PI / 2 + i * angleStep;
    return `${(cx + Math.cos(a) * maxR * val).toFixed(1)},${(cy + Math.sin(a) * maxR * val).toFixed(1)}`;
  }).join(' ');

  const basePts = makePts(baseFp);
  const latestPts = makePts(latestFp);

  const labelsSvg = keys.map((item, i) => {
    const a = -Math.PI / 2 + i * angleStep;
    const lx = cx + Math.cos(a) * (maxR + 24);
    const ly = cy + Math.sin(a) * (maxR + 17);
    const lScore = Number((latestFp && latestFp[item.k]) || 7.5).toFixed(1);
    return `<text x="${lx.toFixed(1)}" y="${ly.toFixed(1)}" fill="#faedcd" font-size="11" font-weight="600" text-anchor="middle" dominant-baseline="middle">${item.label} ${lScore}</text>`;
  }).join('');

  return `
    <svg width="248" height="232" viewBox="0 0 248 232">
      ${gridPolys}
      <polygon points="${basePts}" fill="rgba(244, 162, 97, 0.16)" stroke="#f4a261" stroke-width="1.8" stroke-dasharray="4 3" />
      <polygon points="${latestPts}" fill="rgba(82, 183, 136, 0.28)" stroke="#74c69d" stroke-width="2.3" />
      ${labelsSvg}
    </svg>
  `;
}

function formatDeltaPill(delta, unit = '', invertColor = false) {
  if (delta === null || delta === undefined || Number.isNaN(Number(delta))) {
    return `<span class="delta-pill delta-neutral">--</span>`;
  }
  const num = Number(delta);
  if (Math.abs(num) < 0.001) {
    return `<span class="delta-pill delta-neutral">0${unit ? ' ' + unit : ''} (持平)</span>`;
  }
  const sign = num > 0 ? '+' : '';
  const isGood = invertColor ? num < 0 : num > 0;
  return `<span class="delta-pill ${isGood ? 'delta-pos' : 'delta-neg'}">${sign}${num}${unit ? ' ' + unit : ''}</span>`;
}

async function loadShotComparison(rec, customLeftId = '', customRightId = '') {
  const box = document.getElementById('shotVisualizerSection');
  if (!box || !rec) return;

  const allRecords = (appState.records || []).filter(r => r.record_type !== 'equipment_profile');
  const beanName = rec.bean_name || '';
  const sameBeanPeers = allRecords.filter(r => r.id !== rec.id && beanName && (r.bean_name || '') === beanName);
  const defaultLeft = customLeftId
    || (sameBeanPeers[0] && sameBeanPeers[0].id)
    || ((allRecords.find(r => r.id !== rec.id) || rec).id);
  const defaultRight = customRightId || rec.id;

  const params = new URLSearchParams();
  if (sameBeanPeers.length > 0 && !customLeftId && !customRightId) {
    params.set('bean', beanName);
  }
  params.set('left_id', defaultLeft);
  params.set('right_id', defaultRight);

  try {
    const res = await fetch(`/api/records/compare?${params.toString()}`);
    const cmp = await res.json();
    const base = cmp.baseline_shot || rec;
    const latest = cmp.latest_shot || rec;
    const pd = cmp.parameter_deltas || {};
    const fd = cmp.flavor_radar_delta || {};

    const makeOptions = (selectedId) => allRecords.map(r => {
      const sameFlag = beanName && r.bean_name === beanName ? '🫘 同款豆 · ' : '';
      const label = `${sameFlag}${(r.bean_name || '未命名').slice(0, 12)} (${String(r.created_at || '').slice(5, 16)})`;
      return `<option value="${escapeHtml(r.id)}" ${r.id === selectedId ? 'selected' : ''}>${escapeHtml(label)}</option>`;
    }).join('');

    const gDirMap = { finer: '调细', coarser: '调粗', unchanged: '一致' };
    const grindDeltaObj = pd.grind_setting || {};
    const grindPill = (grindDeltaObj.delta !== null && grindDeltaObj.delta !== undefined && grindDeltaObj.delta !== 0)
      ? `<span class="delta-pill ${grindDeltaObj.delta < 0 ? 'delta-pos' : 'delta-neg'}">${escapeHtml(gDirMap[grindDeltaObj.direction] || '')} (${grindDeltaObj.delta > 0 ? '+' : ''}${escapeHtml(grindDeltaObj.delta)})</span>`
      : `<span class="delta-pill delta-neutral">刻度持平</span>`;

    const insightsHtml = (cmp.insights || []).map(i => `<li>${escapeHtml(i)}</li>`).join('');

    const radarRowsHtml = Object.values(fd).map(ax => `
      <tr>
        <th scope="row">✨ 风味 · ${escapeHtml(ax.label)}</th>
        <td>${escapeHtml(ax.baseline)}</td>
        <td><strong>${escapeHtml(ax.latest)}</strong></td>
        <td>${formatDeltaPill(ax.delta, '分')}</td>
      </tr>
    `).join('');

    const safeCmpRecId = escapeHtml(rec.id);
    box.innerHTML = `
      <div class="visualizer-header">
        <h4>
          📊 同款豆萃取对比 (Visualizer 视图)
          <span class="badge badge-ok">${sameBeanPeers.length > 0 ? `同款豆历史 ${sameBeanPeers.length + 1} 杯` : '跨批次参数对标'}</span>
        </h4>
        <div class="visualizer-controls">
          <label style="font-size:12px; color:var(--text-muted);" for="cmpLeftSelect">Shot A (基准):</label>
          <select id="cmpLeftSelect" class="shot-select" data-record-id="${safeCmpRecId}" onchange="onComparisonSelectChange(this.dataset.recordId)">${makeOptions(base.id)}</select>
          <span style="color:var(--crema);">➔</span>
          <label style="font-size:12px; color:var(--text-muted);" for="cmpRightSelect">Shot B (当前):</label>
          <select id="cmpRightSelect" class="shot-select" data-record-id="${safeCmpRecId}" onchange="onComparisonSelectChange(this.dataset.recordId)">${makeOptions(latest.id)}</select>
        </div>
      </div>

      <div class="visualizer-layout">
        <div class="radar-box" style="width:100%;">
          <h4>🕸️ 双杯风味雷达叠图</h4>
          ${buildDualRadarSvg(base.flavor_profile || {}, latest.flavor_profile || {})}
          <div style="display:flex; gap:12px; font-size:11.5px; margin-top:4px;">
            <span style="color:#f4a261;">┄ Shot A 基准杯</span>
            <span style="color:#74c69d;">━ Shot B 当前杯</span>
          </div>
        </div>

        <div>
          <div tabindex="0" role="region" aria-labelledby="shot-compare-caption" class="table-wrapper">
            <table class="compare-table">
              <caption id="shot-compare-caption">
                Shot A [${escapeHtml((base.bean_name || '').slice(0, 14))} · ${escapeHtml(String(base.created_at || '').slice(5, 16))}] 对比 Shot B [${escapeHtml((latest.bean_name || '').slice(0, 14))} · ${escapeHtml(String(latest.created_at || '').slice(5, 16))}]
              </caption>
              <thead>
                <tr>
                  <th scope="col">核心萃取与感官指标</th>
                  <th scope="col">历史基准 (Shot A)</th>
                  <th scope="col">当前对比 (Shot B)</th>
                  <th scope="col">调整差值 (Delta)</th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <th scope="row">⚖️ 咖啡豆称重 (Dose)</th>
                  <td>${escapeHtml(base.bean_weight_g ?? '--')} g</td>
                  <td><strong>${escapeHtml(latest.bean_weight_g ?? '--')} g</strong></td>
                  <td>${formatDeltaPill(pd.bean_weight_g && pd.bean_weight_g.delta, 'g')}</td>
                </tr>
                <tr>
                  <th scope="row">🎯 研磨度刻度 (Grind)</th>
                  <td>${escapeHtml(base.grind_setting || '--')}</td>
                  <td><strong>${escapeHtml(latest.grind_setting || '--')}</strong></td>
                  <td>${grindPill}</td>
                </tr>
                <tr>
                  <th scope="row">💧 萃取液重 (Yield)</th>
                  <td>${escapeHtml(base.yield_g ?? '--')} g</td>
                  <td><strong>${escapeHtml(latest.yield_g ?? '--')} g</strong></td>
                  <td>${formatDeltaPill(pd.yield_g && pd.yield_g.delta, 'g')}</td>
                </tr>
                <tr>
                  <th scope="row">📐 粉液比 (Brew Ratio)</th>
                  <td>${escapeHtml(base.brew_ratio || '--')}</td>
                  <td><strong>${escapeHtml(latest.brew_ratio || '--')}</strong></td>
                  <td>${formatDeltaPill(pd.brew_ratio && pd.brew_ratio.delta, '')}</td>
                </tr>
                <tr>
                  <th scope="row">⏱️ 萃取时间 (Time)</th>
                  <td>${escapeHtml(base.extraction_time_s ?? '--')} s</td>
                  <td><strong>${escapeHtml(latest.extraction_time_s ?? '--')} s</strong></td>
                  <td>${formatDeltaPill(pd.extraction_time_s && pd.extraction_time_s.delta, 's')}</td>
                </tr>
                <tr>
                  <th scope="row">🧭 萃取压力 (Pressure)</th>
                  <td>${escapeHtml(base.pressure_bar ?? '--')} bar</td>
                  <td><strong>${escapeHtml(latest.pressure_bar ?? '--')} bar</strong></td>
                  <td>${formatDeltaPill(pd.pressure_bar && pd.pressure_bar.delta, 'bar')}</td>
                </tr>
                ${radarRowsHtml}
              </tbody>
            </table>
          </div>
          <ul class="suggestion-list" style="margin-top:12px;">${insightsHtml}</ul>
        </div>
      </div>
    `;
  } catch (err) {
    box.innerHTML = `<div style="font-size:12.5px; color:var(--text-muted);">萃取对比数据加载失败: ${escapeHtml(err)}</div>`;
  }
}

function onComparisonSelectChange(recId) {
  const rec = (appState.records || []).find(r => r.id === recId) || appState.records[0];
  const leftEl = document.getElementById('cmpLeftSelect');
  const rightEl = document.getElementById('cmpRightSelect');
  if (rec && leftEl && rightEl) {
    loadShotComparison(rec, leftEl.value, rightEl.value);
  }
}

function escapeHtml(str) {
  return String(str ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function sanitizeMediaUrl(rawUrl) {
  const url = String(rawUrl ?? '').trim();
  if (!url || /[\r\n\0]/.test(url)) return '';
  if (url.startsWith('/api/media/file?') || url.startsWith('/api/media/keyframe?')) {
    return url;
  }
  try {
    const parsed = new URL(url, window.location.origin);
    if (parsed.protocol === 'http:' || parsed.protocol === 'https:') {
      return parsed.href;
    }
  } catch {
    return '';
  }
  return '';
}


async function sendVoiceUtterance(autoStopIfSingleShot = false) {
  const input = document.getElementById('voiceInput');
  const text = input.value.trim();
  if (!text) {
    showToast('请先输入或说出咖啡制作语音内容');
    return;
  }
  if (autoStopIfSingleShot) {
    const res = await fetch('/api/voice/stop', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        transcript: text,
        reason: '语音流识别完成，相机自动停录并生成咖啡制作报告'
      })
    });
    const data = await res.json();
    input.value = '';
    if (data.record) {
      currentRecordId = data.record.id;
    }
    await fetchState();
    showToast('☕️ 已自动完成视频/语音解析并生成咖啡制作报告！');
    return;
  }

  const res = await fetch('/api/voice/utterance', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text })
  });
  const data = await res.json();
  input.value = '';
  if (data.auto_stopped && data.record) {
    currentRecordId = data.record.id;
    await fetchState();
    switchTab('reports');
    showToast(`⏹️ 已识别到结束指令，自动停止录制并生成报告 [${data.record.id}]！`);
  } else {
    await fetchState();
    const sess = data.session || {};
    if ((sess.transcript_chunks || []).length <= 1) {
      showToast(`🔴 已语音唤醒 ${sess.camera_model || '相机'} 开始录制！请继续口述参数，说「停止录制 / 结束录制」自动生成报告`);
    } else {
      showToast(`🎙️ 已记录过程语音：「${text.slice(0, 28)}」· 说「停止录制」自动结束并出报告`);
    }
  }
}

async function manualVoiceStopAndReport() {
  const input = document.getElementById('voiceInput');
  const extraText = input ? input.value.trim() : '';
  if (extraText) {
    await fetch('/api/voice/utterance', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text: extraText })
    });
    input.value = '';
  }
  const res = await fetch('/api/voice/stop', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      reason: '手动/语音触发停止录制，自动生成本次咖啡制作报告'
    })
  });
  const data = await res.json();
  if (data.record) {
    currentRecordId = data.record.id;
  }
  await fetchState();
  switchTab('reports');
  showToast(`⏹️ 已停止相机录制并自动生成报告 [${data.record ? data.record.id : ''}]！`);
}

async function triggerQuickDemo(mode) {
  let sampleText = '';
  if (mode === 'complete') {
    sampleText = '我要开始制作咖啡。今天咖啡豆用的是巴拿马翡翠庄园红标瑰夏中浅烘，咖啡豆称重 18.2 克，用的是额外独立磨豆机 Weber EG-1，研磨度调到刻度 8.5 格，今天做的是意式浓缩 SOE，萃取压力 9.0 bar，萃取时间 28 秒，出液是 38 克。咖啡制作完成。';
  } else {
    sampleText = '我要开始制作咖啡。今天豆子用的是云南保山厌氧日晒铁皮卡，咖啡豆称重 19 克，做一杯意式浓缩，出液量 38 克。制作完成。';
  }
  document.getElementById('voiceInput').value = sampleText;
  await sendVoiceUtterance(true);
}

async function submitSupplement(recordId) {
  const rec = appState.records.find(r => r.id === recordId);
  const updates = {};
  if (rec && rec.missing_fields) {
    rec.missing_fields.forEach(m => {
      const el = document.getElementById('supp_' + m.field);
      if (el && el.value.trim()) {
        updates[m.field] = el.value.trim();
      }
    });
  }
  const suppVoice = document.getElementById('suppVoiceText') ? document.getElementById('suppVoiceText').value.trim() : '';

  const res = await fetch('/api/records/supplement', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      record_id: recordId,
      updates,
      supplement_text: suppVoice
    })
  });
  const data = await res.json();
  if (data.ok) {
    await fetchState();
    showToast('✅ 缺失参数已补全，完整报告与小红书文案已更新！');
  }
}


let activeSpeechRec = null;
let keepListeningMic = false;

async function triggerVoiceWakeStart() {
  const res = await fetch('/api/voice/wake', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      camera_id: 'pocket4p',
      phrase: '我要开始制作咖啡。'
    })
  });
  const data = await res.json();
  await fetchState();
  const model = (data.voice_session && data.voice_session.camera_model) || 'DJI Osmo Pocket 4 Pro';
  showToast(`🔴 已唤醒 ${model} 开始录制！现在可口述参数，说「停止录制」自动暂停并生成报告`);
}

function startBrowserSpeech() {
  const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
  const micBtn = document.getElementById('btnMicListen');
  if (!SpeechRecognition) {
    showToast('当前浏览器环境不支持 Web Speech API，请直接在输入框输入「开始制作咖啡」或「停止录制」');
    return;
  }

  if (keepListeningMic && activeSpeechRec) {
    keepListeningMic = false;
    try { activeSpeechRec.stop(); } catch (e) {}
    activeSpeechRec = null;
    if (micBtn) micBtn.textContent = '🎤 开启语音监听';
    showToast('⏸️ 已关闭麦克风持续语音监听');
    return;
  }

  keepListeningMic = true;
  const recognition = new SpeechRecognition();
  activeSpeechRec = recognition;
  recognition.lang = 'zh-CN';
  recognition.continuous = true;
  recognition.interimResults = false;

  recognition.onstart = () => {
    if (micBtn) micBtn.textContent = '🔴 正在监听语音 (点击关闭)';
    showToast('🎙️ 麦克风持续监听已开启：说「我要开始制作咖啡」开录，说「停止录制 / 结束录制」自动停录并生成报告');
  };

  recognition.onresult = async (event) => {
    for (let i = event.resultIndex; i < event.results.length; i++) {
      if (event.results[i].isFinal) {
        const transcript = (event.results[i][0].transcript || '').trim();
        if (transcript) {
          document.getElementById('voiceInput').value = transcript;
          await sendVoiceUtterance(false);
        }
      }
    }
  };

  recognition.onerror = (event) => {
    if (event.error === 'not-allowed' || event.error === 'service-not-allowed') {
      keepListeningMic = false;
      if (micBtn) micBtn.textContent = '🎤 开启语音监听';
      showToast('⚠️ 麦克风权限被拒绝，请在浏览器地址栏允许麦克风访问');
    }
  };

  recognition.onend = () => {
    if (keepListeningMic) {
      try { recognition.start(); } catch (e) {}
    } else if (micBtn) {
      micBtn.textContent = '🎤 开启语音监听';
    }
  };

  recognition.start();
}


fetchState();
