// 松萝桌宠 · 纸偶渲染器（puppet）：一张或几张图片 → 会动的桌宠。
//
// 纯 WebGL、零依赖。形象包是声明式数据（pet.json + 图片 + 可选动作），不执行任何包内代码。
// 每张图切成网格，按骨架点（脖子转轴 / 头部范围 / 脚底线）做网格形变：呼吸、摇摆、歪头、
// 弹跳、挤压回弹……多张图按「角色状态」交叉淡入（开心 / 打字 / 睡觉 / 惊讶 / 闭眼眨眼…）。
// 与 pet.js（VRM）、pet-live2d.js 暴露同一套 window.pet* 桥。格式见 docs/pet-puppet-format.md。
(function () {
  'use strict';
  window.__petReady = false;
  window.__petErr = '';

  const params = new URLSearchParams(location.search);
  const packBase = params.get('pack') || '';            // 相对本页，如 packs/<id>/
  const extraZoom = parseFloat(params.get('zoom') || '1') || 1;
  const roam = params.get('roam') === '1';               // 允许溜达（移动窗口）
  const preview = params.get('preview') === '1';         // 形象工坊预览：不自言自语

  function post(message) {
    try { window.webkit?.messageHandlers?.pet?.postMessage(message); } catch (_) {}
  }
  function fail(message) {
    window.__petErr = String(message);
    post({ error: window.__petErr });
    const h = document.getElementById('hint');
    if (h) { h.style.display = 'flex'; h.textContent = window.__petErr; }
  }
  window.addEventListener('error', (e) => fail(e.message || e));
  window.addEventListener('unhandledrejection', (e) => fail((e.reason && e.reason.message) || e.reason || e));

  // ───────────────── WebGL ─────────────────

  const canvas = document.getElementById('c');
  const glOpts = { alpha: true, premultipliedAlpha: true, preserveDrawingBuffer: true, antialias: true };
  const gl = canvas.getContext('webgl2', glOpts) || canvas.getContext('webgl', glOpts);
  if (!gl) { fail('WebGL 不可用'); return; }
  const isGL2 = typeof WebGL2RenderingContext !== 'undefined' && gl instanceof WebGL2RenderingContext;

  const VS = `
    attribute vec2 aPos; attribute vec2 aUV; varying vec2 vUV;
    void main() { vUV = aUV; gl_Position = vec4(aPos, 0.0, 1.0); }`;
  const FS = `
    precision mediump float; varying vec2 vUV; uniform sampler2D uTex; uniform float uAlpha;
    void main() { gl_FragColor = texture2D(uTex, vUV) * uAlpha; }`;
  function shader(type, src) {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  }
  const prog = gl.createProgram();
  gl.attachShader(prog, shader(gl.VERTEX_SHADER, VS));
  gl.attachShader(prog, shader(gl.FRAGMENT_SHADER, FS));
  gl.linkProgram(prog);
  gl.useProgram(prog);
  const aPos = gl.getAttribLocation(prog, 'aPos');
  const aUV = gl.getAttribLocation(prog, 'aUV');
  const uAlpha = gl.getUniformLocation(prog, 'uAlpha');
  gl.enable(gl.BLEND);
  gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);   // 预乘 alpha
  gl.clearColor(0, 0, 0, 0);

  // 网格：GX × GY 个格子（图片坐标归一化，v 自下而上）
  const GX = 20, GY = 28;
  const VCOUNT = (GX + 1) * (GY + 1);
  const indices = [];
  for (let j = 0; j < GY; j++) {
    for (let i = 0; i < GX; i++) {
      const a = j * (GX + 1) + i, b = a + 1, c = a + GX + 1, d = c + 1;
      indices.push(a, b, c, b, d, c);
    }
  }
  const indexBuf = gl.createBuffer();
  gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, indexBuf);
  gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, new Uint16Array(indices), gl.STATIC_DRAW);
  const uvData = new Float32Array(VCOUNT * 2);
  for (let j = 0; j <= GY; j++) {
    for (let i = 0; i <= GX; i++) {
      const k = (j * (GX + 1) + i) * 2;
      uvData[k] = i / GX;
      uvData[k + 1] = 1 - j / GY;      // 贴图行自上而下
    }
  }
  const uvBuf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, uvBuf);
  gl.bufferData(gl.ARRAY_BUFFER, uvData, gl.STATIC_DRAW);
  const posBuf = gl.createBuffer();
  const posData = new Float32Array(VCOUNT * 2);

  function uploadTexture(img) {
    const tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, img);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    if (isGL2) {
      // 原图通常远大于显示尺寸：mipmap 让缩小后的边缘不发毛
      gl.generateMipmap(gl.TEXTURE_2D);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    } else {
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    }
    return tex;
  }

  // ───────────────── 形象包 ─────────────────

  const DEFAULT_RIG = { neck: [0.5, 0.66], head: [0.22, 0.64, 0.78, 1.0], ground: 0 };
  const images = {};        // role → { tex, aspect, rig }
  let library = { actions: {}, triggers: {}, states: {} };
  let lines = {};
  let faces = 'front';      // front | left | right：侧身形象溜达时按方向镜像
  let ready = false;

  const LINES = {
    morning: ['早上好呀', '今天也要加油哦'],
    afternoon: ['下午好', '摸会儿鱼也没关系'],
    evening: ['晚上好', '记得早点休息'],
    click: ['嘿嘿～', '好舒服', '再摸一下嘛', '我在呢'],
    double_click: ['哎呀！', '干嘛呀～', '戳我干嘛'],
    idle: ['你打字真快', '看我看我', '这段写得不错', '要不要喝口水'],
    sleep: ['有点困了…', '呼…'],
    wake: ['我醒了！', '继续吧'],
    level: ['今天打了好多字呀', '继续保持！'],
  };

  function loadImage(src) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => resolve(img);
      img.onerror = () => reject(new Error('图片加载失败：' + src));
      img.src = src;
    });
  }
  async function loadJSON(url) {
    const res = await fetch(url);
    if (!res.ok && res.status !== 0) throw new Error('读取失败：' + url);
    return res.json();
  }

  function sanitizeRig(r) {
    const rig = Object.assign({}, DEFAULT_RIG, r || {});
    const clamp01 = (v, d) => (typeof v === 'number' && isFinite(v) ? Math.max(0, Math.min(1, v)) : d);
    rig.neck = [clamp01(rig.neck?.[0], 0.5), clamp01(rig.neck?.[1], 0.66)];
    const h = rig.head || DEFAULT_RIG.head;
    rig.head = [clamp01(h[0], 0.22), clamp01(h[1], 0.64), clamp01(h[2], 0.78), clamp01(h[3], 1)];
    rig.ground = clamp01(rig.ground, 0);
    return rig;
  }

  function sanitizeAlign(a) {
    const num = (v, d) => (typeof v === 'number' && isFinite(v) ? v : d);
    if (!a || typeof a !== 'object') return { s: 1, dx: 0, dy: 0 };
    return { s: Math.max(0.3, Math.min(3, num(a.s, 1))), dx: Math.max(-1, Math.min(1, num(a.dx, 0))), dy: Math.max(-1, Math.min(1, num(a.dy, 0))) };
  }

  // 没提供的表情图按近似表情兜底（再没有就用平时图）
  const FALLBACK = {
    angry: ['sad'], love: ['shy', 'happy'], tired: ['sleep'], shy: ['happy'],
  };
  function resolveRole(role) {
    if (!role) return null;
    if (images[role]) return role;
    for (const r of FALLBACK[role] || []) if (images[r]) return r;
    return null;
  }

  async function loadPack() {
    library = await loadJSON('./actions.json');
    const pet = await loadJSON(packBase + 'pet.json');
    const puppet = pet.puppet || {};
    faces = puppet.faces || 'front';
    lines = puppet.lines || {};
    // 包内动作：同名覆盖预置；触发/状态映射逐项覆盖
    Object.assign(library.actions, puppet.actions || {});
    Object.assign(library.triggers, puppet.triggers || {});
    Object.assign(library.states, puppet.states || {});
    const entries = Object.entries(puppet.images || {});
    if (!entries.length) throw new Error('形象包没有图片（pet.json 的 puppet.images）');
    await Promise.all(entries.map(async ([role, spec]) => {
      const file = typeof spec === 'string' ? spec : spec.src;
      if (!file || file.includes('..') || file.startsWith('/')) return;
      const img = await loadImage(packBase + file);
      images[role] = {
        tex: uploadTexture(img),
        aspect: img.naturalWidth / Math.max(1, img.naturalHeight),
        rig: sanitizeRig(typeof spec === 'string' ? null : spec.rig),
        // 工坊按「平时」图自动生成的闭眼 / 张嘴图：只和平时图对齐
        generated: typeof spec === 'object' && spec.generated === true,
        // 相对平时图的对齐（缩放 + 平移，单位 = 平时图显示高度）
        align: sanitizeAlign(typeof spec === 'object' ? spec.align : null),
      };
    }));
    if (!images.idle) {
      // 没有标 idle 的就拿第一张当平时
      images.idle = images[entries[0][0]];
    }
  }

  // ───────────────── 动作求值 ─────────────────

  const CHANNELS = ['root.tx', 'root.ty', 'root.rot', 'root.swing', 'root.sx', 'root.sy',
    'alpha', 'breathe', 'lean', 'head.rot', 'head.tx', 'head.ty'];
  const LIMITS = { 'root.tx': 1, 'root.ty': 0.5, 'root.rot': 0.6, 'root.swing': 0.6, 'root.sx': 2.2,
    'root.sy': 0.6, alpha: 1, breathe: 0.2, lean: 0.4, 'head.rot': 0.6, 'head.tx': 0.2, 'head.ty': 0.2 };

  const smooth = (x) => x * x * (3 - 2 * x);
  function evalTrack(track, t, linear) {
    if (Array.isArray(track)) {
      if (!track.length) return 0;
      if (t <= track[0][0]) return track[0][1];
      for (let i = 1; i < track.length; i++) {
        const [t1, v1] = track[i];
        if (t <= t1) {
          const [t0, v0] = track[i - 1];
          const k = t1 > t0 ? (t - t0) / (t1 - t0) : 1;
          return v0 + (v1 - v0) * (linear ? k : smooth(k));
        }
      }
      return track[track.length - 1][1];
    }
    if (track && typeof track === 'object') {
      let v = +track.base || 0;
      if (Array.isArray(track.sin)) {
        const [amp, hz, ph] = track.sin;
        v += (+amp || 0) * Math.sin(2 * Math.PI * (+hz || 0) * t + (+ph || 0));
      }
      if (Array.isArray(track.bob)) {
        const [amp, hz] = track.bob;
        v += (+amp || 0) * Math.abs(Math.sin(Math.PI * (+hz || 0) * t));
      }
      return v;
    }
    return 0;
  }
  function addAction(out, action, t, weight) {
    const tracks = action.tracks || {};
    const linear = action.ease === 'linear';
    for (const ch of CHANNELS) {
      if (tracks[ch] !== undefined) out[ch] += evalTrack(tracks[ch], t, linear) * weight;
    }
  }

  // ───────────────── 状态机 ─────────────────

  let state = 'idle';               // idle | typing | sleep | drag
  let loop = { id: 'idle_loop', since: 0 };
  let prevLoop = null;              // 切换时淡出
  let shots = [];                   // 一次性动作 { action, start }
  let facing = 1;
  let gaze = { x: 0, y: 0 };
  let moodLevel = 0;
  let hovered = false;
  let sleepy = false;
  let dragging = false;
  let typingUntil = 0;
  let lastCommitShot = 0;
  let lastHoverShot = 0;
  let nextIdleAt = 4;
  let nextSayAt = 14;
  let now = 0;

  // 图片（角色状态）：当前与淡出中的上一张
  let curRole = 'idle', prevRole = null, fadeStart = -1;
  const FADE = 0.2;
  let blinkUntil = 0, nextBlinkAt = 2.5;
  let talkUntil = 0, mouthOpen = false, nextMouthAt = 0;

  const pick = (list) => list[Math.floor(Math.random() * list.length)];
  function say(key, force = false) {
    if (preview) return;
    const list = (lines[key] && lines[key].length ? lines[key] : LINES[key]);
    if (!list || !list.length) return;
    if (!force && now < nextSayAt) return;
    nextSayAt = now + 22 + Math.random() * 25;
    post({ say: pick(list) });
  }

  function setLoop(nextState) {
    const id = library.states[nextState] || library.states.idle || 'idle_loop';
    if (loop.id === id) return;
    prevLoop = { id: loop.id, since: loop.since, fadeFrom: now };
    loop = { id, since: now };
  }

  /// 播放一次性动作；返回是否成功。
  function play(id, opts = {}) {
    const action = library.actions[id];
    if (!action || action.loop) return false;
    // 同时最多 2 个叠加，新的挤掉最早的
    shots = shots.filter((s) => s.action !== action);
    if (shots.length >= 2) shots.shift();
    shots.push({ id, action, start: now });
    if (action.effect === 'hearts') post({ hearts: true });
    else if (action.effect === 'sparks') post({ sparks: true });
    if (typeof action.emote === 'string' && action.emote && !preview) post({ emote: action.emote.slice(0, 4) });
    if (Array.isArray(action.say) && action.say.length && !preview) {
      if (opts.force || now >= nextSayAt) {
        nextSayAt = now + 22 + Math.random() * 25;
        post({ say: pick(action.say) });
      }
    }
    if (action.walk && !preview) {
      const dir = Math.random() < 0.5 ? -1 : 1;
      if (faces !== 'front') facing = (faces === 'right' ? dir : -dir);
      post({ walk: dir * (+action.walk || 1), duration: +action.duration || 2 });
    }
    return true;
  }

  function trigger(name, opts = {}) {
    const list = library.triggers[name];
    if (!list) return false;
    const ids = (Array.isArray(list) ? list : [list]).filter((id) => library.actions[id]);
    if (!ids.length) return false;
    return play(pick(ids), opts);
  }

  function activeRole() {
    // 一次性动作的图优先，其次当前循环的图，最后 idle
    for (let i = shots.length - 1; i >= 0; i--) {
      const r = resolveRole(shots[i].action.image);
      if (r) return r;
    }
    const loopAction = library.actions[loop.id];
    const lr = loopAction && resolveRole(loopAction.image);
    if (lr) return lr;
    if (moodLevel >= 3 && images.happy && state === 'idle') return 'happy';
    return 'idle';
  }

  function computeParams() {
    const p = {};
    for (const ch of CHANNELS) p[ch] = 0;
    const cur = library.actions[loop.id];
    if (prevLoop) {
      const k = Math.min(1, (now - prevLoop.fadeFrom) / 0.35);
      const prev = library.actions[prevLoop.id];
      if (prev) addAction(p, prev, now - prevLoop.since, 1 - k);
      if (cur) addAction(p, cur, now - loop.since, k);
      if (k >= 1) prevLoop = null;
    } else if (cur) {
      addAction(p, cur, now - loop.since, 1);
    }
    shots = shots.filter((s) => {
      const t = now - s.start;
      const dur = +s.action.duration || 1;
      if (t > dur) return false;
      // 波形类通道（sin/bob）在首尾 0.2s 内淡入淡出，避免跳变
      const env = Math.min(1, t / 0.2, (dur - t) / 0.2);
      const tracks = s.action.tracks || {};
      for (const ch of CHANNELS) {
        const tr = tracks[ch];
        if (tr === undefined) continue;
        const w = Array.isArray(tr) ? 1 : Math.max(0, env);
        p[ch] += evalTrack(tr, t, s.action.ease === 'linear') * w;
      }
      return true;
    });
    // 注视：头朝鼠标方向轻微偏转
    p['head.rot'] += -gaze.x * 0.035;
    p['head.tx'] += gaze.x * 0.01;
    p['head.ty'] += gaze.y * 0.005;
    for (const ch of CHANNELS) {
      const lim = LIMITS[ch];
      p[ch] = Math.max(-lim, Math.min(lim, p[ch]));
    }
    return p;
  }

  // ───────────────── 形变 + 绘制 ─────────────────

  function layout(entry) {
    const W = canvas.width, H = canvas.height;
    const base = images.idle || entry;
    // 以 idle 图的比例定显示高度；表情图再按工坊里的对齐参数缩放 / 平移，和平时图重合
    const Hb = Math.min(H * 0.86, (W * 0.92) / Math.max(0.2, base.aspect)) * extraZoom;
    const a = entry === base ? { s: 1, dx: 0, dy: 0 } : (entry.align || { s: 1, dx: 0, dy: 0 });
    const Hd = Hb * a.s;
    return { W, H, Hb, Hd, Wd: Hd * entry.aspect, offX: a.dx * Hb, groundY: H * 0.05 + a.dy * Hb };
  }

  function deform(entry, p) {
    const { W, H, Hb, Hd, Wd, offX, groundY } = layout(entry);
    const rig = entry.rig;
    const neckX = (rig.neck[0] - 0.5) * Wd, neckY = (rig.neck[1] - rig.ground) * Hd;
    const [hx0, , hx1] = rig.head;
    const hr = p['head.rot'], hc = Math.cos(hr), hs = Math.sin(hr);
    const sx = 1 + p['root.sx'] - p.breathe * 0.5, sy = 1 + p['root.sy'] + p.breathe;
    const rc = Math.cos(p['root.rot']), rs = Math.sin(p['root.rot']);
    const swc = Math.cos(p['root.swing']), sws = Math.sin(p['root.swing']);
    const topY = Hd * sy;
    const mirror = facing < 0 ? -1 : 1;
    for (let j = 0; j <= GY; j++) {
      const v = j / GY;
      for (let i = 0; i <= GX; i++) {
        const u = i / GX;
        let x = (u - 0.5) * Wd;
        let y = (v - rig.ground) * Hd;
        // 头部权重：脖子以上平滑过渡，水平方向在头部范围外逐渐衰减
        let wh = smooth(Math.max(0, Math.min(1, (v - rig.neck[1] + 0.04) / 0.08)));
        const dxh = u < hx0 ? hx0 - u : (u > hx1 ? u - hx1 : 0);
        wh *= 1 - smooth(Math.min(1, dxh / 0.14));
        if (wh > 0) {
          const ox = x - neckX, oy = y - neckY;
          const qx = ox * hc - oy * hs + neckX + p['head.tx'] * Hd;
          const qy = ox * hs + oy * hc + neckY + p['head.ty'] * Hd;
          x += (qx - x) * wh;
          y += (qy - y) * wh;
        }
        // 身体前后倾：越往上偏移越大（脚底不动）
        const hf = Math.max(0, y / Hd);
        x += p.lean * Math.pow(hf, 1.6) * Hd;
        x *= sx * mirror;
        y *= sy;
        // 绕脚底中心旋转
        let rx = x * rc - y * rs, ry = x * rs + y * rc;
        // 绕头顶摆动（被拎起来）
        const px = rx, py = ry - topY;
        rx = px * swc - py * sws;
        ry = px * sws + py * swc + topY;
        const X = W / 2 + offX + rx + p['root.tx'] * Hb;
        const Y = groundY + ry + p['root.ty'] * Hb;
        const k = (j * (GX + 1) + i) * 2;
        posData[k] = (X / W) * 2 - 1;
        posData[k + 1] = (Y / H) * 2 - 1;
      }
    }
  }

  function drawEntry(entry, p, alpha) {
    if (!entry || alpha <= 0.001) return;
    deform(entry, p);
    gl.bindBuffer(gl.ARRAY_BUFFER, posBuf);
    gl.bufferData(gl.ARRAY_BUFFER, posData, gl.DYNAMIC_DRAW);
    gl.enableVertexAttribArray(aPos);
    gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);
    gl.bindBuffer(gl.ARRAY_BUFFER, uvBuf);
    gl.enableVertexAttribArray(aUV);
    gl.vertexAttribPointer(aUV, 2, gl.FLOAT, false, 0, 0);
    gl.bindTexture(gl.TEXTURE_2D, entry.tex);
    gl.uniform1f(uAlpha, alpha);
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, indexBuf);
    gl.drawElements(gl.TRIANGLES, indices.length, gl.UNSIGNED_SHORT, 0);
  }

  function resize() {
    const dpr = Math.min(window.devicePixelRatio || 2, 3);
    const w = Math.floor(window.innerWidth * dpr), h = Math.floor(window.innerHeight * dpr);
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
    }
    gl.viewport(0, 0, canvas.width, canvas.height);
  }

  /// 该叠加图（闭眼 / 张嘴）能否用在当前表情上：自动生成的只对齐「平时」图
  function overlayFits(entry) {
    return entry && (curRole === 'idle' || (!entry.generated && curRole === 'typing'));
  }

  /// 说话口型：气泡显示期间嘴巴随机开合
  function updateTalk() {
    if (!images.talk || now >= talkUntil || sleepy || !overlayFits(images.talk)) {
      mouthOpen = false;
      return false;
    }
    if (now >= nextMouthAt) {
      mouthOpen = !mouthOpen;
      nextMouthAt = now + (mouthOpen ? 0.08 + Math.random() * 0.1 : 0.06 + Math.random() * 0.12);
    }
    return mouthOpen;
  }

  function updateBlink() {
    const loopAction = library.actions[loop.id];
    if (!images.blink || sleepy || (loopAction && loopAction.noBlink)) return false;
    if (now >= nextBlinkAt) {
      blinkUntil = now + 0.13;
      nextBlinkAt = now + 2.4 + Math.random() * 3.2;
    }
    return now < blinkUntil;
  }

  function scheduleIdle() {
    if (preview || state !== 'idle' || shots.length || now < nextIdleAt) return;
    nextIdleAt = now + 6 + Math.random() * 8;
    if (roam && library.triggers.roam && Math.random() < 0.25) trigger('roam');
    else trigger('idle');
    if (moodLevel >= 2 && Math.random() < 0.15) say('level');
    else if (Math.random() < 0.12) say('idle');
  }

  let lastFrameAt = 0;
  const t0 = performance.now();
  function step() {
    now = (performance.now() - t0) / 1000;
    lastFrameAt = performance.now();
    resize();
    gl.clear(gl.COLOR_BUFFER_BIT);
    if (!ready) return;
    if (state === 'typing' && now > typingUntil) setState('idle');
    scheduleIdle();
    const p = computeParams();
    // 图片切换：交叉淡入
    let role = activeRole();
    if (role !== curRole) {
      prevRole = curRole;
      curRole = role;
      fadeStart = now;
    }
    const blinking = updateBlink() && overlayFits(images.blink);
    const talking = !blinking && updateTalk();
    const alpha = Math.max(0, Math.min(1, 1 + p.alpha));
    const k = fadeStart < 0 ? 1 : Math.min(1, (now - fadeStart) / FADE);
    // 换表情时「压一下再弹回」：交叉淡入的同时轻微挤压，盖住两张图之间的细小差异
    if (k < 1) {
      const pop = Math.sin(Math.PI * k);
      p['root.sy'] -= 0.06 * pop;
      p['root.sx'] += 0.035 * pop;
    }
    if (k < 1 && prevRole) drawEntry(images[prevRole], p, alpha * (1 - k));
    else prevRole = null;
    const face = blinking ? images.blink : (talking ? images.talk : images[curRole]);
    drawEntry(face, p, alpha * (prevRole ? k : 1));
  }
  // 省电：平时 30fps，打盹 12fps；WebKit 遮挡时会节流 rAF，用定时器兜底
  function frameInterval() { return sleepy && !dragging && !hovered ? 1000 / 12 : 1000 / 30; }
  function animate() {
    requestAnimationFrame(animate);
    if (performance.now() - lastFrameAt < frameInterval() - 2) return;
    step();
  }
  setInterval(() => { if (performance.now() - lastFrameAt > 150) step(); }, 100);

  function setState(next) {
    state = next;
    setLoop(next);
  }
  function baseState() {
    if (dragging) return 'drag';
    if (sleepy) return 'sleep';
    return now < typingUntil ? 'typing' : 'idle';
  }

  // ───────────────── Swift → JS 接口（与 pet.js 同名同义） ─────────────────

  window.petSetState = (value) => {
    if (value === 'typing' || value === 'commit') typingUntil = now + 1.2;
    if (value === 'commit' && now - lastCommitShot > 0.4) {
      lastCommitShot = now;
      trigger('commit');
    }
    if (!dragging && !sleepy) setState(value === 'idle' ? 'idle' : 'typing');
  };
  window.petPetted = () => { trigger('click', { force: true }); say('click', true); };
  window.petPoke = () => { trigger('double_click', { force: true }); say('double_click', true); };
  window.petHover = (on) => {
    hovered = !!on;
    if (hovered && now - lastHoverShot > 4 && !shots.length) {
      lastHoverShot = now;
      trigger('hover');
    }
  };
  window.petSetDrag = (on) => {
    dragging = !!on;
    if (!dragging) trigger('drop');
    setState(baseState());
  };
  window.petSetSleepy = (on) => {
    if (sleepy === !!on) return;
    sleepy = !!on;
    if (sleepy) say('sleep');
    else { trigger('wake'); say('wake'); }
    setState(baseState());
  };
  window.petSetMood = (level) => { moodLevel = Math.max(0, Math.min(3, level | 0)); };
  window.petGreet = (period) => { trigger('greet'); say(period); };
  window.petSetGaze = (x, y) => {
    gaze.x = Math.max(-1, Math.min(1, x));
    gaze.y = Math.max(-1, Math.min(1, y));
  };
  /// 通用触发器（milestone / break …）与直接播放动作（形象工坊预览按钮）
  window.petTrigger = (name) => trigger(name, { force: true });
  window.petPlay = (id) => play(id, { force: true });
  /// 播放一个临时动作对象（动作编辑器实时预览，不需要先保存）
  window.petPlayInline = (action) => {
    if (!action || typeof action !== 'object' || action.loop) return false;
    library.actions.__inline = action;
    return play('__inline', { force: true });
  };
  window.petActions = () => JSON.stringify(Object.entries(library.actions)
    .filter(([, a]) => !a.loop).map(([id, a]) => ({ id, name: a.name || id })));
  /// 说话（Swift 弹气泡时调用）：嘴巴开合若干秒
  window.petSpeak = (seconds) => { talkUntil = now + Math.max(0.3, Math.min(4, +seconds || 1)); };
  window.petSetZoom = () => {};
  window.petInfo = () => JSON.stringify({
    ready: !!window.__petReady, renderer: 'puppet', images: Object.keys(images),
    state, loop: loop.id, shots: shots.map((s) => s.id), canvas: [canvas.width, canvas.height],
  });
  window.petCapture = () => canvas.toDataURL('image/png');

  loadPack()
    .then(() => {
      ready = true;
      window.__petReady = true;
      setState('idle');
      post({ ready: true });
    })
    .catch((err) => fail('纸偶形象加载失败：' + String((err && err.message) || err)));
  resize();
  animate();
})();
