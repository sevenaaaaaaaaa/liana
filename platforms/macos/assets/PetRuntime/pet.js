// 松萝桌宠 · VRM 渲染器（three.js + @pixiv/three-vrm）
// 透明背景、跟随鼠标注视、眨眼、呼吸/摇摆、状态机（idle / typing / commit）。
import * as THREE from 'three';
import { GLTFLoader } from './jsm/loaders/GLTFLoader.js';
import { VRMLoaderPlugin, VRMUtils } from './three-vrm.module.js';

window.__petReady = false;
window.__petErr = '';
window.addEventListener('error', (e) => {
  window.__petErr = String(e.message || e);
  try { window.webkit?.messageHandlers?.pet?.postMessage({ error: window.__petErr }); } catch (_) {}
});
window.addEventListener('unhandledrejection', (e) => {
  window.__petErr = String((e.reason && e.reason.message) || e.reason || e);
  try { window.webkit?.messageHandlers?.pet?.postMessage({ error: window.__petErr }); } catch (_) {}
});

const params = new URLSearchParams(location.search);
const modelURL = params.get('model') || './sample.vrm';
const framing = params.get('framing') || 'full';   // full | bust
const extraZoom = parseFloat(params.get('zoom') || '1') || 1;
const canvas = document.getElementById('c');

const renderer = new THREE.WebGLRenderer({
  canvas,
  alpha: true,
  antialias: true,
  premultipliedAlpha: true,
  preserveDrawingBuffer: true,   // 供离屏快照捕获
  powerPreference: 'high-performance',
});
renderer.setClearColor(0x000000, 0);
renderer.outputColorSpace = THREE.SRGBColorSpace;

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(26, 1, 0.05, 50);
const lookTarget = new THREE.Object3D();
scene.add(lookTarget);

// 三点打光：主光暖一点、补光柔、轮廓光偏冷，肤色更通透
scene.add(new THREE.AmbientLight(0xfff4ec, 0.75));
const key = new THREE.DirectionalLight(0xfff0e0, 1.35);
key.position.set(0.7, 1.8, 1.3);
scene.add(key);
const fill = new THREE.DirectionalLight(0xdfe8ff, 0.45);
fill.position.set(-1.2, 1.0, 1.1);
scene.add(fill);
const rim = new THREE.DirectionalLight(0xa9c4ff, 0.7);
rim.position.set(-0.9, 1.5, -1.2);
scene.add(rim);

let vrm = null;
let state = 'idle';
let gaze = { x: 0, y: 0 };
let clock = new THREE.Clock();
let elapsed = 0;
let blink = { next: 1.5, phase: -1 };
let ready = false;

const headTarget = new THREE.Vector3();
let headHeight = 1.4;
// 手臂下垂基准角：VRM0 与 VRM1 的归一化骨骼朝向相反，load 后按 metaVersion 自适应，
// 否则 VRoid(VRM0) 这类模型会一直举着手。
let armBase = { z: -1.16 };

function post(message) {
  try {
    window.webkit?.messageHandlers?.pet?.postMessage(message);
  } catch (_) {}
}

function resize() {
  const w = window.innerWidth;
  const h = window.innerHeight;
  const dpr = Math.min(window.devicePixelRatio || 2, 3);
  renderer.setPixelRatio(dpr);
  renderer.setSize(w, h, false);
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
}
window.addEventListener('resize', resize);

function fitCamera() {
  const box = new THREE.Box3().setFromObject(vrm.scene);
  const size = new THREE.Vector3();
  box.getSize(size);
  headHeight = box.min.y + size.y * 0.90;

  let focusY;
  let distance;
  if (framing === 'bust') {
    focusY = box.min.y + size.y * 0.80;
    distance = size.y * 1.02;
    camera.position.set(0, focusY + size.y * 0.04, distance);
  } else {
    // 全身：略低机位（显高挑），按竖直画幅精确取景
    const aspect = Math.max(0.35, camera.aspect);
    const needV = size.y * 1.06;
    const needH = Math.max(size.x, size.z) * 1.25;
    const fovRad = (camera.fov * Math.PI) / 180;
    distance = Math.max(needV / (2 * Math.tan(fovRad / 2)), needH / (2 * Math.tan(fovRad / 2) * aspect));
    distance /= extraZoom;
    focusY = box.min.y + size.y * 0.52;
    camera.position.set(0, box.min.y + size.y * 0.44, distance);
  }
  camera.near = Math.max(0.05, distance / 200);
  camera.far = distance * 8;
  camera.lookAt(0, focusY, 0);
  camera.updateProjectionMatrix();
  lookTarget.position.set(0, headHeight, distance * 0.5);
  headTarget.set(0, headHeight, 0);
}

function setExpression(name, value) {
  const em = vrm?.expressionManager;
  if (!em) return;
  if (em.getExpression(name)) {
    em.setValue(name, value);
  }
}

function updateBlink(dt) {
  const em = vrm?.expressionManager;
  if (!em) return;
  if (blink.phase < 0) {
    blink.next -= dt;
    if (blink.next <= 0) {
      blink.phase = 0;
    }
    return;
  }
  blink.phase += dt;
  const duration = 0.16;
  let v = 0;
  if (blink.phase < duration) {
    v = Math.sin((blink.phase / duration) * Math.PI);
  } else {
    blink.phase = -1;
    blink.next = 1.6 + Math.random() * 2.6;
  }
  setExpression('blink', v);
}

function applyBasePose() {
  const h = vrm.humanoid;
  const isVRM0 = !!(vrm.meta && String(vrm.meta.metaVersion) === '0');
  armBase.z = isVRM0 ? 1.16 : -1.16;
  const lu = h.getNormalizedBoneNode('leftUpperArm');
  const ru = h.getNormalizedBoneNode('rightUpperArm');
  const ll = h.getNormalizedBoneNode('leftLowerArm');
  const rl = h.getNormalizedBoneNode('rightLowerArm');
  if (lu) lu.rotation.z = armBase.z;
  if (ru) ru.rotation.z = -armBase.z;
  if (ll) ll.rotation.z = armBase.z * 0.19;
  if (rl) rl.rotation.z = -armBase.z * 0.19;
}

// ───────────────── 姿态库（状态 + 随机小动作） ─────────────────

let idleAction = null;
let idleUntil = 0;
let nextIdleAt = 2.5;
let nextSayAt = 14;
let moodLevel = 0;       // 0..3，来自本机输入统计（不上传）
let pettedUntil = 0;
let hovered = false;
let dragging = false;
let sleepy = false;

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
function pick(list) { return list[Math.floor(Math.random() * list.length)]; }
// force：用户直接互动（摸头/戳）必回应，不受闲聊节流限制
function say(list, force = false) {
  const now = performance.now();
  if (!force && now < nextSayAt * 1000) return;
  nextSayAt = now / 1000 + 22 + Math.random() * 25;
  post({ say: pick(list) });
}

function node(name) {
  return vrm && vrm.humanoid ? vrm.humanoid.getNormalizedBoneNode(name) : null;
}

function resetPose() {
  const chest = node('chest');
  const head = node('head');
  const hip = node('hips');
  if (chest) chest.rotation.set(0, 0, 0);
  if (head) head.rotation.set(0, 0, 0);
  if (hip) hip.rotation.set(0, 0, 0);
}

function poseIdle(t) {
  const chest = node('chest');
  const head = node('head');
  if (chest) chest.rotation.x = Math.sin(t * 1.15) * 0.022;        // 呼吸
  if (head) head.rotation.y = Math.sin(t * 0.55) * 0.05;           // 轻微左右看
  vrm.scene.position.y = Math.sin(t * 1.6) * 0.004;
  // 随机小动作
  if (idleAction === 'lookAround' && head) {
    head.rotation.y = Math.sin(t * 3.2) * 0.42;
  } else if (idleAction === 'tilt' && head) {
    head.rotation.z = Math.sin(t * 2.4) * 0.22;
  } else if (idleAction === 'nod' && head) {
    head.rotation.x = 0.06 + Math.sin(t * 6) * 0.2;
  } else if (idleAction === 'sway') {
    if (chest) chest.rotation.z = Math.sin(t * 1.8) * 0.06;
    if (head) head.rotation.z = Math.sin(t * 1.8 + 0.6) * 0.08;
  } else if (idleAction === 'peek' && head) {
    head.rotation.y = 0.5;
    head.rotation.z = -0.2;
  } else if (idleAction === 'hop') {
    vrm.scene.position.y = Math.abs(Math.sin(t * 5.5)) * 0.05;
  } else if (idleAction === 'bounce') {
    vrm.scene.position.y = Math.abs(Math.sin(t * 6)) * 0.03;
    if (head) head.rotation.x = -0.05;
  } else if (idleAction === 'stretch') {
    const l = node('leftUpperArm');
    const r = node('rightUpperArm');
    const k = Math.sin(Math.min(1, t / 1.2) * Math.PI);
    if (l) l.rotation.z = armBase.z - k * 0.7;
    if (r) r.rotation.z = -armBase.z + k * 0.7;
  } else if (idleAction === 'wave') {
    const r = node('rightUpperArm');
    const rl = node('rightLowerArm');
    if (r) r.rotation.z = -armBase.z - 0.9;
    if (rl) rl.rotation.z = -armBase.z * 0.19 + Math.sin(t * 9) * 0.5;
  }
}

function poseTyping(t) {
  const chest = node('chest');
  const head = node('head');
  if (chest) chest.rotation.x = 0.06 + Math.sin(t * 9) * 0.012;    // 前倾 + 跟手颤动
  if (head) head.rotation.x = 0.05;
  vrm.scene.position.y = Math.abs(Math.sin(t * 9)) * 0.006;
}

function poseCommit(t) {
  const chest = node('chest');
  if (chest) chest.rotation.x = -0.05;
  vrm.scene.position.y = Math.abs(Math.sin(t * 3.2)) * 0.05;       // 开心弹跳
}

function posePetted(t) {
  const head = node('head');
  const chest = node('chest');
  if (head) { head.rotation.z = Math.sin(t * 6) * 0.12; head.rotation.x = -0.08; }
  if (chest) chest.rotation.x = -0.04;
  vrm.scene.position.y = Math.abs(Math.sin(t * 7)) * 0.03;
}

function poseSleepy(t) {
  const chest = node('chest');
  const head = node('head');
  if (chest) chest.rotation.x = 0.05 + Math.sin(t * 0.8) * 0.02;
  if (head) { head.rotation.x = 0.28; head.rotation.z = 0.08; }
  vrm.scene.position.y = Math.sin(t * 0.9) * 0.008;
  setExpression('blink', 1);
}

function poseDrag(t) {
  const l = node('leftUpperArm');
  const r = node('rightUpperArm');
  const ll = node('leftLowerArm');
  const rl = node('rightLowerArm');
  const hips = node('hips');
  const head = node('head');
  if (l) l.rotation.z = -2.85;      // 双臂高举（被拎起来）
  if (r) r.rotation.z = 2.85;
  if (ll) ll.rotation.z = -0.5;
  if (rl) rl.rotation.z = 0.5;
  if (hips) hips.rotation.z = Math.sin(t * 5) * 0.12;
  if (head) { head.rotation.x = -0.1; head.rotation.z = Math.sin(t * 5) * 0.1; }
  vrm.scene.position.y = Math.abs(Math.sin(t * 5)) * 0.02;         // 被拎起来晃动
}

function updateGaze() {
  if (!vrm || !vrm.lookAt) return;
  const dx = gaze.x * 0.28;
  const dy = gaze.y * 0.16;
  lookTarget.position.x = dx;
  lookTarget.position.y = headHeight + dy;
  vrm.lookAt.target = lookTarget;
  const head = vrm.humanoid.getNormalizedBoneNode('head');
  if (head && state === 'idle') {
    head.rotation.y += dx * 0.35;
  }
}

function ensureSize() {
  const w = window.innerWidth, h = window.innerHeight;
  const dpr = Math.min(window.devicePixelRatio || 2, 3);
  if (canvas.width !== Math.floor(w * dpr) || canvas.height !== Math.floor(h * dpr)) {
    resize();
  }
}

let lastFrameAt = 0;
// 省电：平时 30fps 足够顺滑，打盹时降到 12fps（桌宠常驻，不该吃满 GPU）
function frameInterval() {
  return sleepy && !dragging && !hovered ? 1000 / 12 : 1000 / 30;
}
function step() {
  ensureSize();
  const dt = Math.min(clock.getDelta(), 0.05);
  elapsed += dt;
  if (vrm) {
    resetPose();
    const nowMs = performance.now();
    if (dragging) {
      poseDrag(elapsed);
    } else if (sleepy) {
      poseSleepy(elapsed);
    } else if (nowMs < pettedUntil) {
      posePetted(elapsed);
    } else if (state === 'typing') {
      poseTyping(elapsed);
    } else if (state === 'commit') {
      poseCommit(elapsed);
    } else {
      // idle：随机小动作调度（3.5–7.5s 一次，持续约 1.4s）
      if (idleAction && nowMs > idleUntil) {
        idleAction = null;
        nextIdleAt = nowMs / 1000 + 3.5 + Math.random() * 4;
      } else if (!idleAction && nowMs / 1000 > nextIdleAt) {
        idleAction = pick(['lookAround', 'tilt', 'nod', 'sway', 'peek', 'hop', 'bounce', 'stretch', 'wave']);
        idleUntil = nowMs + 1400;
      }
      poseIdle(elapsed);
      if (moodLevel >= 2 && Math.random() < 0.002) say(LINES.level);
      else if (Math.random() < 0.0008) say(LINES.idle);
    }
    if (!sleepy) updateBlink(dt);
    updateGaze();
    vrm.update(dt);
  }
  renderer.render(scene, camera);
  lastFrameAt = performance.now();
}
function animate() {
  requestAnimationFrame(animate);
  if (performance.now() - lastFrameAt < frameInterval() - 2) return;
  step();
}
// WebKit 在非激活/遮挡时会节流 rAF：用定时器兜底，保证桌宠始终有动作
setInterval(() => {
  if (performance.now() - lastFrameAt > 150) step();
}, 100);

const loader = new GLTFLoader();
loader.register((parser) => new VRMLoaderPlugin(parser));
loader.load(
  modelURL,
  (gltf) => {
    vrm = gltf.userData.vrm;
    if (!vrm) {
      post({ error: 'not-a-vrm' });
      return;
    }
    VRMUtils.removeUnnecessaryVertices(gltf.scene);
    VRMUtils.combineSkeletons(gltf.scene);
    VRMUtils.rotateVRM0(vrm);
    scene.add(vrm.scene);
    vrm.scene.traverse((obj) => {
      obj.frustumCulled = false;
    });
    fitCamera();
    applyBasePose();
    if (vrm.lookAt) vrm.lookAt.target = lookTarget;
    setExpression('blink', 0);
    // 默认给一个放松/微笑的表情，避免面无表情
    for (const name of ['relaxed', 'happy', 'Fun', 'Joy']) {
        const em = vrm.expressionManager;
        if (em && em.getExpression(name) && (name === 'relaxed')) {
            em.setValue(name, name === 'relaxed' ? 0.6 : 0.3);
        }
    }
    ready = true;
    window.__petReady = true;
    step();
    clock.start();
    post({ ready: true });
  },
  undefined,
  (err) => {
    post({ error: String(err && err.message ? err.message : err) });
  }
);

// Swift → JS 接口
window.petSetState = (value) => {
  const next = value || 'idle';
  // 打字时每次按键都会重复下发 typing：同状态不重置相位，避免动作一卡一卡
  if (next === state && next !== 'commit') return;
  state = next;
  elapsed = 0;
  if (state === 'commit') {
    setExpression('happy', 1);
    setTimeout(() => setExpression('happy', 0), 900);
  }
};
window.petPetted = () => {
  pettedUntil = performance.now() + 1200;
  setExpression('happy', 1);
  setTimeout(() => setExpression('happy', 0), 1200);
  post({ hearts: true });
  say(LINES.petted, true);
};
window.petHover = (on) => {
  hovered = !!on;
};
window.petSetDrag = (on) => {
  dragging = !!on;
  if (!dragging) { pettedUntil = performance.now() + 500; }
};
window.petSetSleepy = (on) => {
  if (sleepy !== !!on) {
    sleepy = !!on;
    if (sleepy) { say(LINES.sleepy); }
    else { setExpression('blink', 0); say(LINES.wake); }
  }
};
window.petSetMood = (level) => {
  moodLevel = Math.max(0, Math.min(3, level | 0));
};
window.petGreet = (period) => {
  idleAction = 'wave';
  idleUntil = performance.now() + 1600;
  say(LINES[period] || LINES.idle);
};
// 戳一戳：惊讶反应（Swift 侧可接 petPoke）
window.petPoke = () => {
  pettedUntil = performance.now() + 900;
  setExpression('surprised', 1);
  setTimeout(() => setExpression('surprised', 0), 900);
  idleAction = 'hop';
  idleUntil = performance.now() + 700;
  say(['哎呀！', '干嘛呀～', '戳我干嘛'], true);
};
window.petSetGaze = (x, y) => {
  gaze.x = Math.max(-1, Math.min(1, x));
  gaze.y = Math.max(-1, Math.min(1, y));
};
window.petInfo = () => JSON.stringify({
  ready: !!window.__petReady,
  triangles: renderer.info.render.triangles,
  calls: renderer.info.render.calls,
  canvas: [canvas.width, canvas.height],
  win: [window.innerWidth, window.innerHeight],
  cam: [camera.position.x, camera.position.y, camera.position.z],
  hasVRM: !!vrm,
});
window.petCapture = () => canvas.toDataURL('image/png');
window.petSetZoom = (factor) => {
  if (!vrm) return;
  const f = Math.max(0.6, Math.min(1.6, factor));
  camera.position.z = camera.position.z / f;
};

resize();
animate();
