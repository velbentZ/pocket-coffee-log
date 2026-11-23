// Multi-device media ingestion & standalone recognition UI (iPhone / iPad / Mac / Web / Audio / Video)

let _lastRecognitionResult = null;
let _ingestSubmitting = false;

function formatBytes(bytes) {
  if (!bytes || bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  let idx = 0;
  let val = Number(bytes);
  while (val >= 1024 && idx < units.length - 1) {
    val /= 1024;
    idx += 1;
  }
  return `${val.toFixed(idx === 0 ? 0 : 1)} ${units[idx]}`;
}

function getSelectedRadioValue(form, name, fallback) {
  const checked = form ? form.querySelector(`input[name="${name}"]:checked`) : null;
  return checked ? checked.value : fallback;
}

function setIngestStatus(msg, isError = false) {
  const el = document.getElementById('ingestStatusText');
  if (!el) return;
  el.textContent = msg;
  el.style.color = isError ? 'var(--accent-red)' : '#74c69d';
}

function setIngestProgress(visible, value = null) {
  const bar = document.getElementById('ingestProgress');
  if (!bar) return;
  bar.hidden = !visible;
  if (!visible) {
    bar.value = 0;
    return;
  }
  if (value === null) {
    bar.removeAttribute('value');
  } else {
    bar.value = Math.max(0, Math.min(100, Math.round(value)));
  }
}

function setIngestBusy(busy) {
  _ingestSubmitting = busy;
  const submitBtn = document.getElementById('btnIngestSubmit');
  const recBtn = document.getElementById('btnRecognizeOnly');
  if (submitBtn) submitBtn.disabled = busy;
  if (recBtn) recBtn.disabled = busy;
}

function updateSelectedFileDisplay() {
  const input = document.getElementById('ingestFileInput');
  const label = document.getElementById('ingestFileSelected');
  if (!input || !label) return;
  const file = input.files && input.files[0];
  if (!file) {
    label.textContent = '未选择文件（也支持只输入文字/口述内容直接生成）';
    return;
  }
  const kind = (file.type || '').startsWith('audio/') || /\.(m4a|wav|mp3|aac|caf|ogg|flac)$/i.test(file.name)
    ? '🎙️ 音频'
    : '🎬 视频';
  label.textContent = `已选择 ${kind}：${file.name} (${formatBytes(file.size)})`;
}

function uploadWithProgress(url, formData, onProgress) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('POST', url, true);
    xhr.upload.addEventListener('progress', (ev) => {
      if (ev.lengthComputable && typeof onProgress === 'function') {
        onProgress((ev.loaded / ev.total) * 85);
      }
    });
    xhr.addEventListener('load', () => {
      try {
        const data = JSON.parse(xhr.responseText || '{}');
        if (xhr.status >= 200 && xhr.status < 300) {
          resolve(data);
        } else {
          reject(new Error(data.error || `HTTP ${xhr.status}`));
        }
      } catch (err) {
        reject(new Error(`解析响应失败 (HTTP ${xhr.status})`));
      }
    });
    xhr.addEventListener('error', () => reject(new Error('网络上传失败，请检查与 Mac 服务器的局域网连接')));
    xhr.send(formData);
  });
}

function renderRecognitionPreview(data) {
  const card = document.getElementById('ingestPreviewCard');
  const body = document.getElementById('ingestPreviewBody');
  if (!card || !body) return;
  _lastRecognitionResult = data;
  card.hidden = false;

  const kindLabel = data.media_kind === 'audio' ? '🎙️ 纯音频文件' : (data.media_kind === 'video' ? '🎬 视频文件' : '📝 文本输入');
  const visualEntries = Object.entries(data.visual_fields || {}).filter(([, v]) => v !== null && v !== undefined && v !== '');
  const visualHtml = visualEntries.length > 0
    ? visualEntries.map(([k, v]) => `<span class="flavor-tag">${escapeHtml(k)}: ${escapeHtml(v)}</span>`).join(' ')
    : '<span style="color:var(--text-muted); font-size:12.5px;">未检测到额外画面数值（将使用语音与豆库/常驻设备补全）</span>';

  const kfs = (data.frame_observations || []).filter(kf => kf && kf.extracted && kf.image_path);
  const kfHtml = kfs.length > 0
    ? `<div class="keyframe-grid" style="margin-top:10px;">${kfs.map(kf => `
        <div class="keyframe-card">
          <div style="font-size:11.5px; color:var(--crema-bright); font-weight:600;">${escapeHtml(kf.stage || kf.stage_key)} (t=${escapeHtml(kf.timestamp_s)}s)</div>
          <img class="report-keyframe-img" src="/api/media/keyframe?path=${encodeURIComponent(kf.image_path)}" alt="${escapeHtml(kf.stage || '')}" loading="lazy" />
        </div>
      `).join('')}</div>`
    : '';

  body.innerHTML = `
    <div style="display:flex; gap:8px; flex-wrap:wrap; margin-bottom:10px;">
      <span class="badge badge-ok">${kindLabel}</span>
      <span class="badge badge-ok">来源: ${escapeHtml(data.source_device || data.source_type || '通用设备')}</span>
      <span class="badge badge-ok">关键帧: ${kfs.length} 张</span>
    </div>
    <div class="supp-field" style="margin-bottom:10px;">
      <label for="previewTranscriptEdit">识别到的语音转写内容（可微调后再生成报告）</label>
      <textarea id="previewTranscriptEdit" class="ingest-textarea" rows="3">${escapeHtml(data.transcript || '')}</textarea>
    </div>
    <div style="margin-bottom:12px;">
      <div style="font-size:12px; color:var(--crema); margin-bottom:6px; font-weight:600;">🔍 画面 OCR / VLM 识别字段：</div>
      <div style="display:flex; gap:6px; flex-wrap:wrap;">${visualHtml}</div>
    </div>
    ${kfHtml}
    <div style="display:flex; gap:10px; flex-wrap:wrap; margin-top:14px;">
      <button class="btn btn-primary" type="button" onclick="generateReportFromPreview('auto')">📋 基于识别结果生成报告 / 录入设备</button>
      <button class="btn" type="button" onclick="generateReportFromPreview('equipment_profile')">⚙️ 强制作为设备档案录入</button>
    </div>
  `;
}

async function runIngestFlow(mode) {
  if (_ingestSubmitting) return;
  const form = document.getElementById('ingestForm');
  const fileInput = document.getElementById('ingestFileInput');
  const noteInput = document.getElementById('ingestTranscriptInput');
  const customDevInput = document.getElementById('ingestCustomDevice');
  const file = fileInput && fileInput.files && fileInput.files[0];
  const transcript = (noteInput ? noteInput.value : '').trim();

  if (!file && !transcript) {
    setIngestStatus('请先选择一个视频/音频文件，或在下方输入口述/文字内容。', true);
    if (fileInput) fileInput.focus();
    return;
  }

  const sourceType = getSelectedRadioValue(form, 'source_type', 'iphone');
  const sourceLabels = {
    iphone: 'iPhone 手机录制',
    ipad: 'iPad 平板录制',
    mac: 'Mac / 录音笔',
    dji_pocket: 'DJI Osmo Pocket',
    web_upload: '通用设备导入',
  };
  const sourceDevice = (customDevInput && customDevInput.value.trim()) || sourceLabels[sourceType] || '通用录制设备';
  const recordIntent = getSelectedRadioValue(form, 'record_intent', 'auto');

  setIngestBusy(true);
  setIngestProgress(true, file ? 5 : null);
  setIngestStatus(mode === 'recognize_only' ? '正在上传并运行独立音视频识别模块...' : '正在上传并执行「识别 → 报告/设备生成」全流程...');

  try {
    let data;
    if (file) {
      const fd = new FormData();
      fd.append('file', file);
      fd.append('source_type', sourceType);
      fd.append('source_device', sourceDevice);
      fd.append('record_intent', recordIntent);
      fd.append('transcript', transcript);
      fd.append('mode', mode);
      const endpoint = mode === 'recognize_only' ? '/api/recognize/media' : '/api/ingest/upload';
      data = await uploadWithProgress(endpoint, fd, (pct) => {
        setIngestProgress(true, pct);
        if (pct >= 84) {
          setIngestStatus('文件已上传，正在进行本地语音转写与画面识别...');
        }
      });
    } else {
      const endpoint = mode === 'recognize_only' ? '/api/recognize/media' : '/api/ingest/process';
      const res = await fetch(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          source_type: sourceType,
          source_device: sourceDevice,
          record_intent: recordIntent,
          transcript,
        }),
      });
      data = await res.json();
      if (!res.ok || !data.ok) {
        throw new Error(data.error || `HTTP ${res.status}`);
      }
    }

    setIngestProgress(true, 100);

    if (mode === 'recognize_only') {
      renderRecognitionPreview(data);
      setIngestStatus('✓ 音视频识别完成！可检查转写与关键帧后，点击下方按钮生成报告或录入设备。');
      showToast('🔍 独立识别模块已完成音视频解析');
      return;
    }

    if (data.rejected_as_non_coffee || data.saved === false) {
      const rejectMsg = data.rejection_reason || '未检测到咖啡制作或器具相关内容，已自动拦截，未写入档案库。';
      setIngestStatus(rejectMsg, true);
      showToast(`🛡️ ${rejectMsg}`);
      return;
    }

    const rec = data.record;
    const isEquip = rec && rec.record_type === 'equipment_profile';
    await fetchState();
    if (rec && rec.id) {
      currentRecordId = rec.id;
      renderRecordList();
      renderSelectedReport();
      switchTab('reports');
    }
    const msg = isEquip
      ? `✓ 已识别为设备介绍并同步至常驻设备库 (${(rec.equipment_items || []).length} 项器具)`
      : `✓ 已生成咖啡制作报告：${(rec && rec.bean_name) || '新记录'}`;
    setIngestStatus(msg);
    showToast(msg);
    if (fileInput) fileInput.value = '';
    updateSelectedFileDisplay();
  } catch (err) {
    setIngestStatus(`处理失败：${err.message || err}`, true);
    showToast(`⚠️ 导入处理失败：${err.message || err}`);
  } finally {
    setIngestBusy(false);
    setTimeout(() => setIngestProgress(false), 900);
  }
}

async function generateReportFromPreview(intentOverride) {
  if (!_lastRecognitionResult || _ingestSubmitting) return;
  const editBox = document.getElementById('previewTranscriptEdit');
  const transcript = (editBox ? editBox.value : _lastRecognitionResult.transcript || '').trim();
  const form = document.getElementById('ingestForm');
  const intent = intentOverride || getSelectedRadioValue(form, 'record_intent', 'auto');

  setIngestBusy(true);
  setIngestStatus('正在调用独立报告生成模块...');
  try {
    const res = await fetch('/api/reports/generate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        transcript,
        source_device: _lastRecognitionResult.source_device || '通用录制设备',
        source_type: _lastRecognitionResult.source_type || 'web_upload',
        media_kind: _lastRecognitionResult.media_kind || 'video',
        media_path: _lastRecognitionResult.media_path || '',
        media_url: _lastRecognitionResult.media_url || '',
        visual_fields: _lastRecognitionResult.visual_fields || {},
        frame_observations: _lastRecognitionResult.frame_observations || [],
        record_intent: intent,
        save: true,
        notify: true,
      }),
    });
    const data = await res.json();
    if (!res.ok || !data.ok) {
      throw new Error(data.error || `HTTP ${res.status}`);
    }
    await fetchState();
    if (data.record && data.record.id) {
      currentRecordId = data.record.id;
      renderRecordList();
      renderSelectedReport();
      switchTab('reports');
    }
    const msg = data.record_type === 'equipment_profile'
      ? '✓ 已基于识别结果录入常驻设备档案'
      : '✓ 已基于识别结果生成咖啡制作报告';
    setIngestStatus(msg);
    showToast(msg);
  } catch (err) {
    setIngestStatus(`生成失败：${err.message || err}`, true);
    showToast(`⚠️ 报告生成失败：${err.message || err}`);
  } finally {
    setIngestBusy(false);
  }
}

function initIngestModule() {
  const form = document.getElementById('ingestForm');
  const fileInput = document.getElementById('ingestFileInput');
  const dropZone = document.getElementById('ingestDropZone');
  const recBtn = document.getElementById('btnRecognizeOnly');

  if (form) {
    form.addEventListener('submit', (e) => {
      e.preventDefault();
      runIngestFlow('ingest');
    });
  }
  if (recBtn) {
    recBtn.addEventListener('click', () => runIngestFlow('recognize_only'));
  }
  if (fileInput) {
    fileInput.addEventListener('change', updateSelectedFileDisplay);
  }
  if (dropZone && fileInput) {
    ['dragenter', 'dragover'].forEach((evName) => {
      dropZone.addEventListener(evName, (e) => {
        e.preventDefault();
        dropZone.classList.add('is-dragover');
      });
    });
    ['dragleave', 'drop'].forEach((evName) => {
      dropZone.addEventListener(evName, (e) => {
        e.preventDefault();
        dropZone.classList.remove('is-dragover');
      });
    });
    dropZone.addEventListener('drop', (e) => {
      const files = e.dataTransfer && e.dataTransfer.files;
      if (files && files.length > 0) {
        fileInput.files = files;
        updateSelectedFileDisplay();
      }
    });
  }
}

document.addEventListener('DOMContentLoaded', initIngestModule);
