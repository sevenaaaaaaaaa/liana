// 松萝桌宠 · Live2D 渲染器（pixi.js + pixi-live2d-display，方案 A：自带运行时）
//
// 与 pet.js（VRM）暴露同一套 window.pet* 桥，供 Swift 侧 VRMPetView/Live2DPetView 无差别驱动。
// 依赖（见同目录 README.md）：
//   - vendor/pixi.min.js、vendor/pixi-live2d-display.min.js（MIT，随包）
//   - live2dcubismcore.min.js（Live2D Cubism Core，专有，用户自备，ADR-0009）
(function () {
  window.__petReady = false;
  window.__petErr = '';

  const params = new URLSearchParams(location.search);
  const modelURL = params.get('model') || '';
  const framing = params.get('framing') || 'full';      // full | bust
  const extraZoom = parseFloat(params.get('zoom') || '1') || 1;
  const extraScale = parseFloat(params.get('scale') || '1') || 1;

  function post(message) {
    try { window.webkit?.messageHandlers?.pet?.postMessage(message); } catch (_) {}
  }
  function showHint(text) {
    const h = document.getElementById('hint');
    if (h) { h.style.display = 'flex'; h.textContent = text; }
  }
  function fail(message, needsRuntime) {
    window.__petErr = String(message);
    post(needsRuntime ? { needsRuntime: true, error: window.__petErr } : { error: window.__petErr });
    showHint(window.__petErr);
  }
  window.addEventListener('error', (e) => fail(e.message || e));
  window.addEventListener('unhandledrejection', (e) => fail((e.reason && e.reason.message) || e.reason || e));

  // ── 运行时依赖自检（缺一即明确报错，不静默降级） ──
  if (!window.PIXI) { fail('Live2D 运行时未就绪：缺少 vendor/pixi.min.js', true); return; }
  if (!window.Live2DCubismCore) {
    fail('Live2D 运行时未就绪：缺少 live2dcubismcore.min.js\n请放入 ~/Library/Application Support/Liana/live2d-user/core/', true);
    return;
  }
  if (!(window.PIXI.live2d && window.PIXI.live2d.Live2DModel)) {
    fail('Live2D 运行时未就绪：缺少 vendor/pixi-live2d-display.min.js', true);
    return;
  }
  if (!modelURL) { fail('未指定 Live2D 模型（检查 pet.json 的 entry）'); return; }

  // ── 状态 ──
  let model = null;
  let state = 'idle';
  let gaze = { x: 0, y: 0 };
  let moodLevel = 0;
  let hovered = false;
  let dragging = false;
  let sleepy = false;
  let pettedUntil = 0;
  let baseScale = 1;
  let nextSayAt = 14;

  const LINES = {
    morning: ['早上好呀', '今天也要加油哦'],
    afternoon: ['下午好', '摸会儿鱼也没关系'],
    evening: ['晚上好', '记得早点休息'],
    petted: ['嘿嘿～', '好舒服', '再摸一下嘛', '我在呢'],
    idle: ['你打字真快', '看我看我', '这段写得不错', '要不要喝口水'],
    sleepy: ['有点困了…', '呼…'],
    wake: ['我醒了！', '继续吧'],
    level: ['今天打了好多字呀', '继续保持！'],
  };
  // 状态 → Cubism 动作组名（pet.json 的 states 可覆盖，PR-3 接线）
  const MOTION_MAP = { idle: 'Idle', typing: 'TapBody', commit: 'TapHead' };
  const pick = (list) => list[Math.floor(Math.random() * list.length)];
  function say(list, force = false) {
    const now = performance.now();
    if (!force && now < nextSayAt * 1000) return;
    nextSayAt = now / 1000 + 22 + Math.random() * 25;
    post({ say: pick(list) });
  }

  const app = new PIXI.Application({
    view: document.getElementById('c'),
    transparent: true,
    antialias: true,
    autoStart: true,
    resizeTo: window,
    backgroundAlpha: 0,
    preserveDrawingBuffer: true,
  });
  app.stage.interactive = true;
  app.stage.hitArea = app.screen;

  function fit() {
    if (!model) return;
    const w = app.screen.width, h = app.screen.height;
    const mw = model.internalModel?.width || model.width || 1;
    const mh = model.internalModel?.height || model.height || 1;
    // 画幅：full 全身 / bust 半身（放大并下移取景）
    const cover = framing === 'bust' ? 0.86 : 0.96;
    const s = Math.min(w / mw, h / mh) / cover * extraZoom * extraScale;
    baseScale = s;
    model.scale.set(s);
    model.anchor.set(0.5, framing === 'bust' ? 1.35 : 1.0);
    model.position.set(w / 2, framing === 'bust' ? h * 1.28 : h);
  }

  function playMotion(group) {
    if (!model || !group) return;
    try { model.motion(group); } catch (_) {}
  }
  function setExpression(id) {
    if (!model || !id) return;
    try { model.expression(id); } catch (_) {}
  }
  function applyState() {
    if (!model) return;
    if (sleepy) { playMotion('Idle'); return; }
    playMotion(MOTION_MAP[state] || MOTION_MAP.idle);
  }

  function updateGaze() {
    if (!model || typeof model.focus !== 'function') return;
    const cx = app.screen.width / 2 + gaze.x * app.screen.width / 2;
    const cy = app.screen.height / 2 + gaze.y * app.screen.height / 2;
    try { model.focus(cx, cy); } catch (_) {}
  }

  function step() {
    if (!model) return;
    const now = performance.now();
    if (dragging) { playMotion('Idle'); }
    else if (now < pettedUntil) { /* 摸头动作由 petPetted 触发 */ }
    if (moodLevel >= 2 && Math.random() < 0.002) say(LINES.level);
    else if (!sleepy && Math.random() < 0.0008) say(LINES.idle);
    updateGaze();
  }
  app.ticker.add(step);

  PIXI.live2d.Live2DModel.from(modelURL, { autoInteract: false, autoUpdate: true })
    .then((m) => {
      model = m;
      app.stage.addChild(model);
      fit();
      window.addEventListener('resize', fit);
      applyState();
      window.__petReady = true;
      post({ ready: true });
    })
    .catch((err) => fail('Live2D 模型加载失败：' + String((err && err.message) || err)));

  // ── Swift → JS 接口（与 pet.js 同名同义） ──
  window.petSetState = (value) => {
    const next = value || 'idle';
    // 打字时每次按键都会重复下发 typing：同状态不重播动作
    if (next === state && next !== 'commit') return;
    state = next;
    applyState();
  };
  window.petPetted = () => {
    pettedUntil = performance.now() + 1200;
    playMotion('TapHead');
    post({ hearts: true });
    say(LINES.petted, true);
  };
  window.petPoke = () => {
    pettedUntil = performance.now() + 900;
    playMotion('TapBody');
    say(['哎呀！', '干嘛呀～', '戳我干嘛'], true);
  };
  window.petHover = (on) => { hovered = !!on; };
  window.petSetDrag = (on) => { dragging = !!on; };
  window.petSetSleepy = (on) => {
    if (sleepy !== !!on) {
      sleepy = !!on;
      if (sleepy) say(LINES.sleepy); else say(LINES.wake);
      // 打盹：整体略暗、减速；醒来恢复
      if (model) model.alpha = sleepy ? 0.78 : 1;
      app.ticker.speed = sleepy ? 0.5 : 1;
      applyState();
    }
  };
  window.petSetMood = (level) => { moodLevel = Math.max(0, Math.min(3, level | 0)); };
  window.petGreet = (period) => { say(LINES[period] || LINES.idle); };
  window.petSetGaze = (x, y) => {
    gaze.x = Math.max(-1, Math.min(1, x));
    gaze.y = Math.max(-1, Math.min(1, y));
  };
  window.petSetZoom = (factor) => {
    if (!model) return;
    const f = Math.max(0.6, Math.min(1.6, factor));
    model.scale.set(baseScale * f);
  };
  window.petHitTest = (x, y) => {
    if (!model || typeof model.hitTest !== 'function') return '[]';
    try { return JSON.stringify(model.hitTest(x, y) || []); } catch (_) { return '[]'; }
  };
  window.petInfo = () => JSON.stringify({
    ready: !!window.__petReady,
    renderer: 'live2d',
    hasModel: !!model,
    screen: [app.screen.width, app.screen.height],
  });
  window.petCapture = () => {
    try { return app.view.toDataURL('image/png'); } catch (_) { return ''; }
  };
})();
