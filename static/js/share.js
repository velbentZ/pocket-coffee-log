// Multi-platform sharing, 3:4 canvas poster export & accessible clipboard helpers
// Accessible clipboard helper (Async Clipboard API + synchronous legacyCopy fallback)
function legacyCopyText(text) {
  const field = Object.assign(document.createElement('textarea'), { value: text });
  field.setAttribute('readonly', '');
  field.style.cssText = 'position:fixed;inset-block-start:0;opacity:0';
  document.body.append(field);
  field.select();
  try {
    return document.execCommand('copy');
  } catch {
    return false;
  } finally {
    field.remove();
  }
}

async function copyTextWithFallback(text) {
  const value = String(text || '').trim();
  if (!value) return false;
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      await navigator.clipboard.writeText(value);
      return true;
    }
  } catch {
    // Fall through to synchronous legacyCopy fallback for non-HTTPS LAN contexts
  }
  return legacyCopyText(value);
}

async function copyTextValue(id, msg) {
  const el = document.getElementById(id);
  if (!el) return;
  const ok = await copyTextWithFallback(el.value !== undefined ? el.value : el.textContent);
  showToast(ok ? msg : '❌ 复制失败，请检查浏览器剪贴板权限');
}

async function copyTextById(id, msg) {
  const el = document.getElementById(id);
  if (!el) return;
  const ok = await copyTextWithFallback(el.innerText || el.textContent);
  showToast(ok ? msg : '❌ 复制失败，请检查浏览器剪贴板权限');
}

function buildJikeWeiboCopy(rec) {
  if (rec.record_type === 'equipment_profile') {
    const tools = (rec.equipment_items || []).map(i => i.name.split(' ')[0]).slice(0, 6).join(' / ');
    return `☕️ 用 ${rec.camera_device} 给家里的咖啡角做了一次全自动设备建档！\n主力机：${rec.grinder_model || '格米莱 G3828A 研磨一体机'}\n常驻器具：${tools || '自动回弹压粉锤 / 布粉器 / 58mm双嘴手柄 / 丸型滤纸 / 桌面吸尘器'}\n口粮豆：${rec.bean_name || '咸芝士低因 SOE'}\n#居家咖啡角 #家庭咖啡馆 #Pocket4Pro`;
  }
  const isColdBrew = (rec.brew_method || '').includes('冷萃');
  const tStr = rec.extraction_time_s
    ? (isColdBrew && rec.extraction_time_s >= 3600 ? `${(rec.extraction_time_s / 3600).toFixed(1)}h` : `${rec.extraction_time_s}s`)
    : '--s';
  return `☕️ 今日出杯打卡｜${rec.bean_name || '精选咖啡豆'} (${rec.brew_method || '意式浓缩'})\n⚖️ ${rec.bean_weight_g || '--'}g 粉 ➔ ${rec.yield_g || '--'}g 液 (${rec.brew_ratio || '--'}) | ⏱️ ${tStr} @ ${rec.pressure_bar ?? '--'} bar\n⚙️ ${rec.grinder_model || rec.grinder_type || '磨豆机'} (${rec.grind_setting || '--'})\n✨ 风味：${(rec.flavor_notes || []).join(' · ')}\n🎥 ${rec.camera_device} LAN STA 自动记录 #每日咖啡打卡 #居家咖啡角`;
}

function buildMarkdownCopy(rec) {
  if (rec.record_type === 'equipment_profile') {
    const rows = (rec.equipment_items || []).map(it => `| ${it.category || '常驻器具'} | **${it.name}** | ${it.spec || '--'} | ${it.role || '--'} |`).join('\n');
    return `## ⚙️ 居家咖啡角常驻设备与器具档案 (${rec.created_at})\n\n- **录制设备**: ${rec.camera_device}\n- **主力咖啡机 & 磨豆机**: ${rec.grinder_model || '格米莱 G3828A'}\n- **常驻口粮豆**: ${rec.bean_name || '--'}\n\n| 类别 | 器具名称 | 规格参数 | 作用与动线 |\n| :--- | :--- | :--- | :--- |\n${rows}\n\n> 🎙️ **原始口述归档**: ${rec.transcript || ''}`;
  }
  return `## ☕️ 咖啡萃取报告 · ${rec.bean_name || '精选咖啡豆'} (${rec.created_at})\n\n| 参数项 | 实测数值 | 参数项 | 实测数值 |\n| :--- | :--- | :--- | :--- |\n| **制作方式** | ${rec.brew_method || '--'} | **咖啡豆称重** | ${rec.bean_weight_g ?? '--'} g |\n| **磨豆设备** | ${rec.grinder_model || rec.grinder_type || '--'} | **研磨刻度** | ${rec.grind_setting || '--'} |\n| **出液量 / 粉液比** | ${rec.yield_g ?? '--'} g (${rec.brew_ratio || '--'}) | **耗时 / 压力** | ${rec.extraction_time_s ?? '--'}s @ ${rec.pressure_bar ?? '--'} bar |\n\n- **风味表现**: ${(rec.flavor_notes || []).join(' · ')}\n- **AI 咖啡师诊断**: ${rec.extraction_diagnosis || ''}\n- **优化建议**: ${(rec.suggestions || []).join('；')}`;
}


function drawRoundedRectPath(ctx, x, y, w, h, r) {
  const radius = Math.min(r, w / 2, h / 2);
  ctx.beginPath();
  ctx.moveTo(x + radius, y);
  ctx.lineTo(x + w - radius, y);
  ctx.quadraticCurveTo(x + w, y, x + w, y + radius);
  ctx.lineTo(x + w, y + h - radius);
  ctx.quadraticCurveTo(x + w, y + h, x + w - radius, y + h);
  ctx.lineTo(x + radius, y + h);
  ctx.quadraticCurveTo(x, y + h, x, y + h - radius);
  ctx.lineTo(x, y + radius);
  ctx.quadraticCurveTo(x, y, x + radius, y);
  ctx.closePath();
}

function drawCoverImage(ctx, img, x, y, w, h, r = 10) {
  ctx.save();
  drawRoundedRectPath(ctx, x, y, w, h, r);
  ctx.clip();
  const iw = img.naturalWidth || img.width || w;
  const ih = img.naturalHeight || img.height || h;
  const scale = Math.max(w / iw, h / ih);
  const sw = w / scale;
  const sh = h / scale;
  const sx = (iw - sw) / 2;
  const sy = (ih - sh) / 2;
  ctx.drawImage(img, sx, sy, sw, sh, x, y, w, h);
  ctx.restore();
}

function buildPosterCanvas(recordId) {
  const rec = appState.records.find(r => r.id === recordId) || appState.records[0];
  if (!rec) return null;
  const isEquip = rec.record_type === 'equipment_profile';
  const canvas = document.createElement('canvas');
  canvas.width = 900;
  canvas.height = 1200;
  const ctx = canvas.getContext('2d');

  // 1. Magazine-grade Espresso background gradient + double frame
  const grad = ctx.createLinearGradient(0, 0, 900, 1200);
  grad.addColorStop(0, '#2d1e17');
  grad.addColorStop(0.5, '#150f0c');
  grad.addColorStop(1, '#261912');
  ctx.fillStyle = grad;
  ctx.fillRect(0, 0, 900, 1200);

  ctx.strokeStyle = '#d4a373';
  ctx.lineWidth = 3.5;
  ctx.strokeRect(30, 30, 840, 1140);
  ctx.strokeStyle = 'rgba(243, 198, 143, 0.22)';
  ctx.lineWidth = 1.2;
  ctx.strokeRect(40, 40, 820, 1120);

  // 2. Header badge + Title + Flavor/Equipment Notes
  drawRoundedRectPath(ctx, 68, 62, 430, 36, 18);
  ctx.fillStyle = '#f3c68f';
  ctx.fill();
  ctx.fillStyle = '#1a120e';
  ctx.font = 'bold 18px -apple-system, PingFang SC, sans-serif';
  ctx.fillText(isEquip ? '⚙️ POCKET COFFEE STUDIO · 居家咖啡角装备档案' : '☕️ POCKET COFFEE STUDIO · 每日咖啡打卡', 84, 86);

  ctx.fillStyle = '#a8988e';
  ctx.font = '18px -apple-system, PingFang SC, sans-serif';
  ctx.textAlign = 'right';
  ctx.fillText(`🎥 ${rec.camera_device}`, 832, 86);
  ctx.textAlign = 'left';

  ctx.fillStyle = '#faedcd';
  ctx.font = 'bold 40px -apple-system, PingFang SC, sans-serif';
  ctx.fillText((rec.bean_name || '今日精选咖啡豆').slice(0, 20), 68, 150);

  const isColdBrew = (rec.brew_method || '').includes('冷萃');
  const timeDisp = rec.extraction_time_s
    ? (isColdBrew && rec.extraction_time_s >= 3600 ? `${(rec.extraction_time_s / 3600).toFixed(1)} h` : `${rec.extraction_time_s} s`)
    : '-- s';

  ctx.fillStyle = '#d4a373';
  ctx.font = '22px -apple-system, PingFang SC, sans-serif';
  ctx.fillText(
    `${rec.brew_method || '意式浓缩'}  |  ${rec.bean_roast || '精品烘焙'}  |  ✨ ${(rec.flavor_notes || []).slice(0, 4).join(' · ') || '花果平衡'}`.slice(0, 38),
    68,
    192
  );

  // 3. Core 6 Cards (either 6 Equipment Accessories or 6 Brew Metrics)
  const items = isEquip
    ? (rec.equipment_items || []).slice(0, 6).map(it => [it.category || '常驻器具', it.name || '--'])
    : [
        ['咖啡豆称重 (Dose)', `${rec.bean_weight_g || '--'} g`],
        ['出液量 / 粉液比', `${rec.yield_g || '--'} ${isColdBrew ? 'ml' : 'g'} (${rec.brew_ratio || '--'})`],
        ['研磨设备类型', `${rec.grinder_type || '--'}`],
        ['磨豆机 & 刻度', `${(rec.grinder_model || '').slice(0, 10)} · ${rec.grind_setting || '--'}`],
        ['萃取时间 (Time)', timeDisp],
        ['萃取压力 (Pressure)', `${rec.pressure_bar ?? '--'} bar`],
      ];

  items.forEach((it, idx) => {
    const col = idx % 2;
    const row = Math.floor(idx / 2);
    const x = 68 + col * 392;
    const y = 216 + row * 98;
    drawRoundedRectPath(ctx, x, y, 372, 84, 12);
    ctx.fillStyle = 'rgba(0, 0, 0, 0.42)';
    ctx.fill();
    ctx.strokeStyle = 'rgba(212, 163, 115, 0.32)';
    ctx.lineWidth = 1.4;
    ctx.stroke();

    ctx.fillStyle = '#a8988e';
    ctx.font = '18px -apple-system, PingFang SC, sans-serif';
    ctx.fillText(String(it[0]).slice(0, 18), x + 20, y + 32);

    ctx.fillStyle = '#f3c68f';
    ctx.font = isEquip ? 'bold 21px -apple-system, PingFang SC, sans-serif' : 'bold 25px -apple-system, PingFang SC, sans-serif';
    ctx.fillText(String(it[1]).slice(0, 18), x + 20, y + 67);
  });

  // 4. Middle Visual Studio Row
  const midY = 524;
  const midH = 336;
  const loadedKfImgs = Array.from(document.querySelectorAll('.report-keyframe-img'))
    .filter(img => (!img.dataset.recordId || img.dataset.recordId === rec.id) && img.complete && img.naturalWidth > 0);

  if (isEquip && loadedKfImgs.length >= 2) {
    // Equipment Showcase: 2x2 Real Keyframe Photo Grid across the entire middle row
    drawRoundedRectPath(ctx, 68, midY, 764, midH, 16);
    ctx.fillStyle = 'rgba(14, 10, 8, 0.62)';
    ctx.fill();
    ctx.strokeStyle = 'rgba(212, 163, 115, 0.34)';
    ctx.lineWidth = 1.5;
    ctx.stroke();

    ctx.fillStyle = '#f3c68f';
    ctx.font = 'bold 20px -apple-system, PingFang SC, sans-serif';
    ctx.fillText('🖼️ 相机 4 阶段咖啡角装备实拍快照 (1280px 高清关键帧)', 90, midY + 34);

    loadedKfImgs.slice(0, 4).forEach((imgEl, idx) => {
      const col = idx % 2;
      const row = Math.floor(idx / 2);
      const slotW = 356;
      const slotH = 128;
      const slotX = 86 + col * 378;
      const slotY = midY + 48 + row * 140;
      try {
        drawCoverImage(ctx, imgEl, slotX, slotY, slotW, slotH, 10);
        ctx.strokeStyle = 'rgba(243, 198, 143, 0.45)';
        ctx.lineWidth = 1.5;
        drawRoundedRectPath(ctx, slotX, slotY, slotW, slotH, 10);
        ctx.stroke();

        const stageTag = imgEl.dataset.stageLabel || `E${idx + 1} 装备特写`;
        drawRoundedRectPath(ctx, slotX + 10, slotY + slotH - 32, 178, 24, 6);
        ctx.fillStyle = 'rgba(18, 14, 12, 0.84)';
        ctx.fill();
        ctx.fillStyle = '#f3c68f';
        ctx.font = 'bold 13px -apple-system, PingFang SC, sans-serif';
        ctx.fillText(`📷 ${stageTag}`, slotX + 18, slotY + slotH - 15);
      } catch (drawErr) {}
    });
  } else {
    // Left Panel: 6-Axis Sensory Flavor Radar Chart
    drawRoundedRectPath(ctx, 68, midY, 372, midH, 16);
    ctx.fillStyle = 'rgba(14, 10, 8, 0.62)';
    ctx.fill();
    ctx.strokeStyle = 'rgba(212, 163, 115, 0.34)';
    ctx.lineWidth = 1.5;
    ctx.stroke();

    ctx.fillStyle = '#f3c68f';
    ctx.font = 'bold 20px -apple-system, PingFang SC, sans-serif';
    ctx.fillText('📊 感官风味六维雷达', 90, midY + 34);

    const fp = rec.flavor_profile || {};
    const radarAxes = [
      { k: 'acidity', label: '酸质' },
      { k: 'sweetness', label: '甜感' },
      { k: 'body', label: '醇厚' },
      { k: 'aroma', label: '香气' },
      { k: 'aftertaste', label: '余韵' },
      { k: 'balance', label: '平衡' },
    ];
    const rCx = 254;
    const rCy = midY + 194;
    const maxR = 92;
    const angleStep = (Math.PI * 2) / radarAxes.length;

    [0.35, 0.68, 1.0].forEach(level => {
      ctx.beginPath();
      radarAxes.forEach((_, i) => {
        const a = -Math.PI / 2 + i * angleStep;
        const px = rCx + Math.cos(a) * maxR * level;
        const py = rCy + Math.sin(a) * maxR * level;
        if (i === 0) ctx.moveTo(px, py);
        else ctx.lineTo(px, py);
      });
      ctx.closePath();
      ctx.strokeStyle = 'rgba(212, 163, 115, 0.22)';
      ctx.lineWidth = 1.2;
      ctx.stroke();
    });

    radarAxes.forEach((_, i) => {
      const a = -Math.PI / 2 + i * angleStep;
      ctx.beginPath();
      ctx.moveTo(rCx, rCy);
      ctx.lineTo(rCx + Math.cos(a) * maxR, rCy + Math.sin(a) * maxR);
      ctx.strokeStyle = 'rgba(212, 163, 115, 0.16)';
      ctx.lineWidth = 1;
      ctx.stroke();
    });

    const dataVertices = radarAxes.map((ax, i) => {
      const rawScore = Number(fp[ax.k] ?? 7.8);
      const norm = Math.min(10, Math.max(1, rawScore)) / 10.0;
      const a = -Math.PI / 2 + i * angleStep;
      return {
        x: rCx + Math.cos(a) * maxR * norm,
        y: rCy + Math.sin(a) * maxR * norm,
        lx: rCx + Math.cos(a) * (maxR + 30),
        ly: rCy + Math.sin(a) * (maxR + 24),
        label: ax.label,
        score: rawScore.toFixed(1),
      };
    });

    ctx.beginPath();
    dataVertices.forEach((pt, i) => {
      if (i === 0) ctx.moveTo(pt.x, pt.y);
      else ctx.lineTo(pt.x, pt.y);
    });
    ctx.closePath();
    ctx.fillStyle = 'rgba(212, 163, 115, 0.36)';
    ctx.fill();
    ctx.strokeStyle = '#f3c68f';
    ctx.lineWidth = 2.8;
    ctx.stroke();

    dataVertices.forEach(pt => {
      ctx.beginPath();
      ctx.arc(pt.x, pt.y, 4.2, 0, Math.PI * 2);
      ctx.fillStyle = '#faedcd';
      ctx.fill();

      ctx.fillStyle = '#faedcd';
      ctx.font = 'bold 15px -apple-system, PingFang SC, sans-serif';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText(`${pt.label} ${pt.score}`, pt.lx, pt.ly);
    });
    ctx.textAlign = 'left';
    ctx.textBaseline = 'alphabetic';

    // Right Panel: Keyframe Snapshots or Barista Signature Badge
    drawRoundedRectPath(ctx, 460, midY, 372, midH, 16);
    ctx.fillStyle = 'rgba(14, 10, 8, 0.62)';
    ctx.fill();
    ctx.strokeStyle = 'rgba(212, 163, 115, 0.34)';
    ctx.lineWidth = 1.5;
    ctx.stroke();

    const top2Imgs = loadedKfImgs.slice(0, 2);
    let compositedCount = 0;
    if (top2Imgs.length > 0) {
      ctx.fillStyle = '#f3c68f';
      ctx.font = 'bold 20px -apple-system, PingFang SC, sans-serif';
      ctx.fillText('🖼️ 相机实拍关键帧快照', 482, midY + 34);

      top2Imgs.forEach((imgEl, idx) => {
        const slotH = top2Imgs.length === 1 ? 262 : 126;
        const slotY = midY + 50 + idx * (slotH + 14);
        try {
          drawCoverImage(ctx, imgEl, 480, slotY, 332, slotH, 10);
          ctx.strokeStyle = 'rgba(243, 198, 143, 0.45)';
          ctx.lineWidth = 1.5;
          drawRoundedRectPath(ctx, 480, slotY, 332, slotH, 10);
          ctx.stroke();

          const stageTag = imgEl.dataset.stageLabel || `关键帧 #${idx + 1}`;
          drawRoundedRectPath(ctx, 490, slotY + slotH - 34, 150, 26, 6);
          ctx.fillStyle = 'rgba(18, 14, 12, 0.82)';
          ctx.fill();
          ctx.fillStyle = '#f3c68f';
          ctx.font = 'bold 14px -apple-system, PingFang SC, sans-serif';
          ctx.fillText(`📷 ${stageTag}`, 500, slotY + slotH - 16);
          compositedCount += 1;
        } catch (drawErr) {}
      });
    }

    if (compositedCount === 0) {
      const avgScore = (
        radarAxes.reduce((acc, ax) => acc + Number(fp[ax.k] ?? 7.8), 0) / radarAxes.length
      ).toFixed(1);

      ctx.fillStyle = '#f3c68f';
      ctx.font = 'bold 20px -apple-system, PingFang SC, sans-serif';
      ctx.fillText('🏆 BARISTA SIGNATURE · 认证印章', 482, midY + 36);

      drawRoundedRectPath(ctx, 482, midY + 56, 328, 118, 14);
      ctx.fillStyle = 'rgba(212, 163, 115, 0.12)';
      ctx.fill();
      ctx.strokeStyle = 'rgba(243, 198, 143, 0.45)';
      ctx.lineWidth = 1.5;
      ctx.stroke();

      ctx.fillStyle = '#faedcd';
      ctx.font = 'bold 48px -apple-system, PingFang SC, sans-serif';
      ctx.fillText(`${avgScore}`, 504, midY + 126);
      ctx.fillStyle = '#d4a373';
      ctx.font = 'bold 20px -apple-system, PingFang SC, sans-serif';
      ctx.fillText('/ 10.0 感官综合均分', 606, midY + 112);
      ctx.fillStyle = '#74c69d';
      ctx.font = '17px -apple-system, PingFang SC, sans-serif';
      ctx.fillText(rec.status === 'complete' ? '✓ 黄金萃取参数核验通过' : '✦ 多模态 AI 实时复盘', 606, midY + 144);

      const stageBadges = [
        'P1 15% 电子秤称豆精准识别',
        'P2 35% 磨豆机刀盘刻度定位',
        'P3 70% 9bar 压力表与虎斑油脂',
        'P4 90% 出杯液重与读秒终点',
      ];
      stageBadges.forEach((txt, i) => {
        ctx.fillStyle = '#e2d5ce';
        ctx.font = '17px -apple-system, PingFang SC, sans-serif';
        ctx.fillText(`✦ ${txt}`, 488, midY + 210 + i * 32);
      });
    }
  }

  // 5. AI Barista Diagnosis & Next-Brew Suggestion Card
  drawRoundedRectPath(ctx, 68, 878, 764, 212, 16);
  ctx.fillStyle = 'rgba(0, 0, 0, 0.38)';
  ctx.fill();
  ctx.strokeStyle = 'rgba(212, 163, 115, 0.28)';
  ctx.lineWidth = 1.3;
  ctx.stroke();

  ctx.fillStyle = '#f3c68f';
  ctx.font = 'bold 23px -apple-system, PingFang SC, sans-serif';
  ctx.fillText(isEquip ? '💡 居家咖啡角装备档案 & 动线建议:' : '💡 AI 咖啡师萃取复盘与建议:', 92, 916);

  ctx.fillStyle = '#f5ebe6';
  ctx.font = '21px -apple-system, PingFang SC, sans-serif';
  const diag = ((rec.extraction_diagnosis || '') + ' ' + ((rec.suggestions && rec.suggestions[0]) || '')).trim();
  for (let i = 0; i < 4; i++) {
    const line = diag.slice(i * 33, (i + 1) * 33);
    if (line) ctx.fillText(line, 92, 956 + i * 34);
  }

  // 6. Footer Signature
  ctx.fillStyle = '#a8988e';
  ctx.font = '18px -apple-system, PingFang SC, sans-serif';
  ctx.fillText(`记录编号: ${rec.id}   |   时间: ${rec.created_at}`, 68, 1130);
  ctx.textAlign = 'right';
  ctx.fillStyle = '#d4a373';
  ctx.fillText('Pocket Coffee Studio · LAN STA :8088', 832, 1130);
  ctx.textAlign = 'left';

  return { canvas, rec };
}

function exportPosterImage(recordId) {
  const built = buildPosterCanvas(recordId);
  if (!built) return;
  const { canvas, rec } = built;
  const link = document.createElement('a');
  link.download = `${rec.id}-poster.png`;
  link.href = canvas.toDataURL('image/png');
  link.click();
  showToast('🖼️ 已导出 3:4 高清分享海报 (.png)！');
}

async function copyPosterImageToClipboard(recordId) {
  const built = buildPosterCanvas(recordId);
  if (!built) return false;
  const { canvas } = built;
  try {
    const blob = await new Promise(resolve => canvas.toBlob(resolve, 'image/png'));
    if (blob && navigator.clipboard && window.ClipboardItem) {
      await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })]);
      showToast('📋 高清海报图片已复制到系统剪贴板！可在微信/小红书直接按 Cmd+V 粘贴图片');
      return true;
    }
  } catch (err) {
    // Fallback to download if clipboard image write is restricted
  }
  exportPosterImage(recordId);
  return false;
}

async function nativeSystemShare(recordId) {
  const built = buildPosterCanvas(recordId);
  if (!built) return;
  const { canvas, rec } = built;
  const shareText = rec.wechat_copy || rec.xiaohongshu_copy || '';
  try {
    const blob = await new Promise(resolve => canvas.toBlob(resolve, 'image/png'));
    if (navigator.share && blob) {
      const file = new File([blob], `${rec.id}-poster.png`, { type: 'image/png' });
      if (navigator.canShare && navigator.canShare({ files: [file] })) {
        await navigator.share({
          title: rec.bean_name || 'Pocket Coffee Studio 报告',
          text: shareText,
          files: [file],
        });
        showToast('📤 已调起系统原生分享面板（支持 AirDrop / 微信 / 备忘录）');
        return;
      }
      await navigator.share({
        title: rec.bean_name || 'Pocket Coffee Studio 报告',
        text: shareText,
      });
      showToast('📤 已调起系统原生分享面板');
      return;
    }
  } catch (err) {
    if (err && err.name === 'AbortError') return;
  }
  await copyPosterImageToClipboard(recordId);
}

async function quickSharePlatform(recordId, platform) {
  const rec = appState.records.find(r => r.id === recordId) || appState.records[0];
  if (!rec) return;

  if (platform === 'xiaohongshu') {
    const text = rec.xiaohongshu_copy || '';
    const copiedText = await copyTextWithFallback(text);
    exportPosterImage(recordId);
    showToast('📕 已复制小红书种草文案并下载高清海报图，正在打开小红书创作服务平台...');
    window.open('https://creator.xiaohongshu.com/publish/publish', '_blank', 'noopener');
    return;
  }

  if (platform === 'wechat') {
    const copiedImg = await copyPosterImageToClipboard(recordId);
    showToast(copiedImg
      ? '💬 海报图片已复制！打开微信聊天/朋友圈直接 Cmd+V 粘贴图片，再点击「复制微信文案」即可'
      : '💬 已下载高清海报图，可直接拖入微信发送！');
    return;
  }

  if (platform === 'weibo') {
    const text = buildJikeWeiboCopy(rec);
    const copiedText = await copyTextWithFallback(text);
    exportPosterImage(recordId);
    showToast('🔥 已复制短图文打卡文案并导出配图，正在打开微博发布页...');
    window.open(`https://service.weibo.com/share/share.php?title=${encodeURIComponent(text)}`, '_blank', 'noopener');
    return;
  }

  if (platform === 'markdown') {
    const md = buildMarkdownCopy(rec);
    const copiedMd = await copyTextWithFallback(md);
    showToast(copiedMd ? '📝 已复制 Notion / Markdown 表格档案，可直接粘贴到 Notion、飞书或 Obsidian！' : '❌ 复制 Markdown 失败，请检查剪贴板权限');
  }
}

