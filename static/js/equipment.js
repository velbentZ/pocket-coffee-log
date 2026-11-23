// Bean inventory, label scanning & permanent equipment profile management
function renderBeansTab() {
  const lib = appState.bean_library || {};
  const beans = lib.beans || [];
  const eq = lib.equipment || {};

  const listEl = document.getElementById('beanLibraryList');
  if (listEl) {
    listEl.innerHTML = beans.map(b => {
      const initW = Math.max(1, Number(b.initial_weight_g ?? 250));
      const remW = Math.max(0, Number(b.remaining_weight_g ?? 200));
      const pct = Math.min(100, Math.round((remW / initW) * 100));
      const fillColor = remW <= 0 || pct <= 12
        ? 'var(--accent-red)'
        : (pct <= 30 ? 'var(--accent-amber)' : 'var(--accent-green)');

      const stage = b.freshness_stage || '黄金赏味期 (Peak Window)';
      const daysOff = (b.days_off_roast !== null && b.days_off_roast !== undefined)
        ? `烘焙后 ${b.days_off_roast} 天`
        : '烘焙期未填';
      const freshBadgeClass = stage.includes('养豆期')
        ? 'badge-fresh-degas'
        : (stage.includes('衰退') ? 'badge-fresh-aging' : 'badge-fresh-peak');

      const statusMap = { active: '🟢 开封在用', frozen: '❄️ 冷冻锁鲜', finished: '🏁 已喝完空袋' };
      const bagStatusLabel = statusMap[b.bag_status] || '🟢 开封在用';
      const brewCount = Number(b.brew_count ?? 0);

      return `
        <div class="record-item">
          <div class="record-item-top" style="flex-wrap:wrap; gap:6px;">
            <span style="font-size:12px; color:var(--crema-bright); font-weight:700;">🎙️ 语音简称: ${escapeHtml((b.short_aliases || []).join(' / '))}</span>
            <div style="display:flex; gap:6px; flex-wrap:wrap;">
              <span class="badge ${freshBadgeClass}">🌿 ${escapeHtml(stage)} · ${escapeHtml(daysOff)}</span>
              <span class="badge badge-ok">☕️ 累计冲煮 ${brewCount} 次</span>
            </div>
          </div>
          <div class="record-bean">${escapeHtml(b.full_name)}</div>
          <div class="record-meta" style="margin-top:4px; flex-wrap:wrap; gap:6px;">
            <span>产区/处理: <strong>${escapeHtml(b.origin || '--')} · ${escapeHtml(b.process || '--')} (${escapeHtml(b.roast_level || '中浅烘')})</strong></span>
            <span>烘焙日: <code>${escapeHtml(b.roast_date || '--')}</code> · ${bagStatusLabel}</span>
          </div>
          <div class="record-meta" style="margin-top:4px; flex-wrap:wrap; gap:6px;">
            <span>推荐刻度: <strong>${escapeHtml(b.recommended_grind || '--')}</strong></span>
            <span>✨ ${escapeHtml((b.flavor_tags || []).join(' · '))}</span>
          </div>
          <div class="bean-inventory-row">
            <div class="bean-inventory-labels">
              <span>📦 豆袋余量进度: <strong style="color:var(--latte);">${remW}g</strong> / ${initW}g (${pct}%)</span>
              <span style="color:var(--crema);">约可再萃 ${Math.max(0, Math.floor(remW / Number(b.recommended_dose_g || 18)))} 杯</span>
            </div>
            <progress
              class="bean-weight-progress"
              max="${initW}"
              value="${Math.min(initW, remW)}"
              style="--progress-bar-fill: ${fillColor};"
              aria-label="${escapeHtml(b.full_name)} 剩余克重 ${remW} 克，总重 ${initW} 克"
            ></progress>
          </div>
          <div style="font-size:11.5px; color:var(--crema); margin-top:6px;">🏆 黄金配方: ${escapeHtml(b.golden_recipe_note || '--')}</div>
        </div>
      `;
    }).join('');
  }

  if (document.getElementById('eqGrinderType')) {
    document.getElementById('eqGrinderType').value = eq.default_grinder_type || '咖啡机自带磨豆机';
    document.getElementById('eqGrinderModel').value = eq.default_grinder_model || '格米莱 G3828A (云象One 内置60mm平刀磨豆机)';
    document.getElementById('eqSecGrinderModel').value = eq.espresso_machine || eq.secondary_grinder_model || '格米莱 G3828A (云象One 研磨一体咖啡机)';
    document.getElementById('eqWaterTemp').value = eq.default_water_temp_c || 93.0;
  }

  let accContainer = document.getElementById('eqAccessoriesGallery');
  if (!accContainer && document.getElementById('eqWaterTemp')) {
    const eqCard = document.getElementById('eqWaterTemp').closest('.camera-card');
    if (eqCard) {
      accContainer = document.createElement('div');
      accContainer.id = 'eqAccessoriesGallery';
      accContainer.style.marginTop = '18px';
      eqCard.appendChild(accContainer);
    }
  }
  if (accContainer) {
    const accessories = eq.accessories || [];
    if (accessories.length > 0) {
      const accItemsHtml = accessories.map(it => {
        const imgHtml = it.image_path
          ? `<img src="/api/media/keyframe?path=${encodeURIComponent(it.image_path)}" alt="${escapeHtml(it.name)}" style="width:100%; height:110px; object-fit:cover; border-radius:8px; margin-top:6px; border:1px solid rgba(212,163,115,0.28);" loading="lazy" />`
          : '';
        return `
          <div class="record-item" style="cursor:default;">
            <div class="record-item-top">
              <span style="font-size:11.5px; color:var(--crema-bright); font-weight:700;">🛠️ ${escapeHtml(it.category || '常驻器具')}</span>
              <span class="badge badge-ok">✓ 已建档</span>
            </div>
            <div class="record-bean" style="font-size:14px;">${escapeHtml(it.name)}</div>
            <div style="font-size:12px; color:var(--crema); margin-top:3px;">${escapeHtml(it.spec || '')}</div>
            <div style="font-size:11.5px; color:var(--text-muted); margin-top:2px;">${escapeHtml(it.role || '')}</div>
            ${imgHtml}
          </div>
        `;
      }).join('');
      accContainer.innerHTML = `
        <div style="padding-top:14px; border-top:1px dashed var(--border-subtle);">
          <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:10px;">
            <h4 style="font-size:14px; color:var(--crema-bright); margin:0;">🛠️ 视频语音自动建档 · 居家咖啡角常驻器具清单 (${accessories.length} 项)</h4>
            <span class="badge badge-ok">录制介绍自动补充</span>
          </div>
          <div class="supplement-grid">${accItemsHtml}</div>
        </div>
      `;
    } else {
      accContainer.innerHTML = '';
    }
  }

  const usb = appState.usb_status || {};
  const usbEl = document.getElementById('usbProbeStatusText');
  if (usbEl) {
    const serials = escapeHtml((usb.serial_ports || []).join(', ') || '未检测到 DJI 串口');
    const product = escapeHtml(usb.detected_camera_product || 'OsmoPocket');
    usbEl.innerHTML = `当前已连接 DJI 串口/音频节点: <code>${serials}</code> | 相机 USB-C 直连状态: <strong>${usb.camera_usb_connected ? '🟢 已连接真机 (' + product + ')' : '⚪ 等待插入 Pocket 3 / Pocket 4 Pro USB-C 数据线'}</strong>`;
  }
}

function fillSampleBeanLabel() {
  const input = document.getElementById('scanLabelInput');
  if (input) {
    input.value = '巴拿马翡翠庄园红标瑰夏 日晒 浅烘 200g 柑橘茉莉花水蜜桃 烘焙日期 2026-11-10';
    input.focus();
  }
}

async function scanBeanLabel() {
  const input = document.getElementById('scanLabelInput');
  const statusEl = document.getElementById('scanLabelStatus');
  const text = input ? input.value.trim() : '';
  if (!text) {
    showToast('请先输入或粘贴咖啡豆袋标签描述文本');
    return;
  }
  const res = await fetch('/api/beans/scan_label', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text })
  });
  const data = await res.json();
  if (!data.ok || !data.bean) {
    if (statusEl) statusEl.textContent = `⚠️ 解析失败: ${data.error || '请检查输入内容'}`;
    showToast(data.error || '豆袋标签解析失败');
    return;
  }
  const b = data.bean;
  if (document.getElementById('newBeanAliases')) {
    document.getElementById('newBeanAliases').value = (b.short_aliases || []).join(', ');
    document.getElementById('newBeanFullName').value = b.full_name || '';
    document.getElementById('newBeanRoast').value = b.roast_level || '中浅烘焙';
    document.getElementById('newBeanRoastDate').value = b.roast_date || '';
    document.getElementById('newBeanInitWeight').value = b.initial_weight_g || 250;
    document.getElementById('newBeanGrind').value = b.recommended_grind || '刻度 14.0 格';
    document.getElementById('newBeanFlavors').value = (b.flavor_tags || []).join(', ');
    document.getElementById('newBeanNote').value = b.golden_recipe_note || '';
  }
  if (statusEl) {
    statusEl.textContent = `✅ 已自动解析入库：「${b.full_name}」| 产区: ${b.origin} | 处理法: ${b.process} | 烘焙度: ${b.roast_level} | 净重: ${b.initial_weight_g}g | ${b.freshness_stage}`;
  }
  await fetchState();
  showToast(`🏷️ AI 已解析豆袋「${b.name || b.full_name}」并同步至豆仓！`);
}

async function submitTasteFeedback(recordId, rating, tasteTag) {
  const res = await fetch('/api/records/feedback', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ record_id: recordId, rating, taste_tag: tasteTag })
  });
  const data = await res.json();
  if (data.ok) {
    await fetchState();
    showToast('👅 已记录您的主观品鉴反馈，AI 已更新下次研磨与萃取建议！');
  }
}

async function saveNewBean() {
  const fullName = document.getElementById('newBeanFullName').value.trim();
  const aliases = document.getElementById('newBeanAliases').value.trim();
  if (!fullName || !aliases) {
    showToast('请填写咖啡豆唤醒简称和完整名称');
    return;
  }
  const initW = parseFloat(document.getElementById('newBeanInitWeight')?.value || '250') || 250.0;
  const roastDate = document.getElementById('newBeanRoastDate')?.value.trim() || '';
  await fetch('/api/beans/save', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      short_aliases: aliases,
      full_name: fullName,
      roast_level: document.getElementById('newBeanRoast').value.trim(),
      roast_date: roastDate,
      initial_weight_g: initW,
      remaining_weight_g: initW,
      recommended_grind: document.getElementById('newBeanGrind').value.trim(),
      flavor_tags: document.getElementById('newBeanFlavors').value.trim(),
      golden_recipe_note: document.getElementById('newBeanNote').value.trim()
    })
  });
  await fetchState();
  showToast('🫘 新咖啡豆已加入常驻豆仓！之后做咖啡只需说简称即可自动匹配。');
}

async function saveEquipmentProfile() {
  await fetch('/api/equipment/save', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      default_grinder_type: document.getElementById('eqGrinderType').value.trim(),
      default_grinder_model: document.getElementById('eqGrinderModel').value.trim(),
      secondary_grinder_model: document.getElementById('eqSecGrinderModel').value.trim(),
      default_water_temp_c: parseFloat(document.getElementById('eqWaterTemp').value) || 93.0
    })
  });
  await fetchState();
  showToast('⚙️ 常驻磨豆机与设备预设已保存！');
}

