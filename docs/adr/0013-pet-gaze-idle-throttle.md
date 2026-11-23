# ADR-0013：桌宠空闲时不再向 WKWebView 推 JS（2026-11-23 整机冻结）

状态：已接受（2026-11-23）

## 背景

2026-11-23 10:12，机器连续运行约一天、完全空闲（黑屏、无键鼠）时整机冻结，只能强制断电。
故障前 90 秒的统一日志里，Liana 一个进程写了 2700 条 `ProcessDidResume`（30 条/秒，占全系统日志 66%），
同一时段 powerd 12 秒内 7 次 `Sleep revert`，随后一行日志都没有，直到用户断电重启。

现场复现（2026-11-23 19:57，v0.30.0 build 31，屏幕亮着但 HID 已空闲 436 秒，鼠标一动不动）：
`scripts/check-liana-idle.sh` 量到 30 秒内 **450 次** `runJavaScriptInFrameInScriptWorld`
（= 15 次/秒），日志 8570 行；同一窗口 `ProcessDidResume` 为 0 —— 因为此时 WebContent 还在前台，
还没开始被节流。

机制（日志逐条对得上，不是推测）：

1. `PetWindow.followTick` 跑在 30Hz 的 `shakeTimer` 上，`pollTick % 2 == 0` 时调
   `petView.setGaze(...)` → `evaluateJavaScript`，**与用户有没有动作无关**。
2. WebKit 为每一次 `runJavaScriptInFrameInScriptWorld` 创建一个 foreground
   `ProcessThrottler::Activity`，调用返回后立刻 invalidate；create 与 invalidate 各触发一次
   `updateThrottleStateIfNeeded`，各发一条 `ProcessDidResume`。15 次/秒 × 2 = **30 条/秒**，
   与故障现场的数字完全一致（2700 / 90 秒 = 900 / 30 秒）。
3. 息屏 / 锁屏 / 遮挡时 `NSWindow.isVisible` 仍为 true，这条 30Hz 循环照跑；`setPause` 只让
   页面停了 rAF，Swift 侧照样每 33ms 敲一次门。WebKit 想把 WebContent 降级或挂起，
   每 33ms 又被一个 foreground activity 拽回来 → powerd 反复 `Sleep revert` → 最终整机冻结。
4. 症状随运行时间累积：WebContent 要先进入「被节流」状态才会开始这条乒乓，刚启动时窗口总是
   可见/前台，所以「重启后干净、跑一两天才发作」。

**这不是候选词窗口的问题**：出事的是桌宠（VRM / Live2D / 纸偶）的 `WKWebView`，
它常驻、且与输入焦点无关。候选词窗口走的是原生 AppKit（`CandidateWindow.swift`），不含 WebKit。

同一窗口里还有 `corespotlight:index` 的 donation 失败（`CSIndexErrorDomain -1000`，14 次/30 秒）。
仓库里没有任何 `CSSearchableIndex` 调用（全仓 grep 零命中），它是同一个卡顿窗口里的伴随现象，
不是独立的重试循环；本 ADR 不动它。

## 决策

1. **注视按变化推，不按帧推**（`Sources/PetGazeGate.swift`）：把「这一帧要不要发 JS」做成纯函数，
   与上一帧差异小于 0.02 就不发；`reset()` 供从暂停恢复时补一帧。
2. **看不见就不跑**：`pauseReasons` 非空或 `panel.isVisible == false` 时 `followTick` 一帧 JS 都不发；
   `setPause` 进入暂停时 `stopShakeTimer()`，恢复时 `startShakeTimerIfNeeded()` ——
   30Hz 计时器本身停掉，不只是停渲染。
3. **WebKit 渲染器不建帧计时器**：`restartAnimTimer()` 对 `petView != nil` 直接返回。
   它每一下都命中 `tick()` 的早退分支，纯空转（3–9Hz）。
4. **WebView 侧再兜一层**：`PetWebView.setGaze` 在 `pausedForHidden` 时直接 return。
5. **回归闸门**：`scripts/check-liana-idle.sh` 量 JS 次数 / resume 次数 / 瞬时 CPU，
   并用 `HIDIdleTime` 判断窗口是否真的空闲（没空满窗口就把 JS 一项标 SKIP，只判 resume）；
   `platforms/macos/tests/PetGazeGateTests.swift` 钉住「静帧 900 次不许推一次」。

## 备选（没采用）

- **把 30Hz 降到 1Hz**：不解决问题。暂停时每秒仍然拽一次被节流的 WebContent；而且注视肉眼可见地卡。
- **把注视计算搬进页面，监听 mousemove**：桌宠窗口 `hitTest` 返回 nil，页面收不到鼠标事件；
  要全局监听就得 `CGEventTap` + 辅助功能权限，和 0.30.0 刚删掉全局键盘监听的方向相反。
- **放弃 WebKit 渲染器**：代价太大，VRM / Live2D 只能靠 WebGL。

## 后果

- 空闲（鼠标不动）时 `runJavaScriptInFrameInScriptWorld` 从 15 次/秒降到 **0**；
  日志从 8570 行/30 秒降到个位数。
- 鼠标真的在动时仍是 15Hz，观感不变 —— 页面侧本来就在插值。
- 暂停期间 `pollSecureInput` / `pollVoice` 也停了（原本 15 个 tick 一次）。看不见的时候不需要
  「捂眼睛」和「竖耳朵」，恢复后第一轮就会补上。
- 验收口径（用户给的）：空闲 `ProcessDidResume` 每 30 秒 = 0；空闲 CPU < 2%；
  窗口不可见时零 WebKit activity；连续 48 小时累计 ≤ 10 次。前三项可用
  `scripts/check-liana-idle.sh` 现场量，第四项只能长跑。
