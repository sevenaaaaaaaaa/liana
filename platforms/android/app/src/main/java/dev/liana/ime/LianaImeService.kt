package dev.liana.ime

import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONObject

/**
 * 全平台统一设计 Token（docs/design/UNIFIED-DESIGN.md 为单一事实源）。
 */
object LianaTheme {
    const val BG = 0xFF1C1C22.toInt()
    const val KEY = 0xFF2A2A33.toInt()
    const val KEY_PRESSED = 0xFF33333E.toInt()
    const val TEXT = 0xFFE8E8EC.toInt()
    const val SECONDARY = 0xFF9A9AA5.toInt()
    const val ACCENT = 0xFF337BFF.toInt()
    const val RADIUS_KEY = 8f          // dp
    const val FONT_CANDIDATE = 17f
    const val FONT_KEY = 16f
    const val KEY_HEIGHT = 46          // dp（可见键高，与 iOS 一致）
    const val PAD_SPLIT_MIN_WIDTH = 600 // dp，Pad / 折叠内屏分体阈值
}

/**
 * 松萝 Android 输入法服务。
 *
 * 与 macOS 端同构：Swift 外壳的职责（会话管理 / 候选栏 / 键盘）在这里用
 * framework API 重写，引擎逻辑全部来自同一份 Rust 内核（libliana_jni.so）。
 *
 * 触控创新（统一设计语言 §3）：
 * - 全键触觉反馈（§3.1）
 * - 候选上滑直上屏（§3.2）
 * - 退格长按连删 + 左滑整段清除（§3.3）
 * - 折叠屏几何守恒 + 中缝工作台（FOLDABLE-ADAPTATION.md §4 §5）
 */
class LianaImeService : InputMethodService() {

    // ---- 输入状态（与视图生命周期解耦：折叠/展开重建视图不得丢失） ----
    private var session: Long = 0
    private var modeIdx = 0
    private var candidates: List<String> = emptyList()
    private var rawInput: String = ""
    private var composingText: String = ""

    // ---- 视图 ----
    private lateinit var candidateStrip: LinearLayout
    private lateinit var keyboardArea: LinearLayout
    private var modeButton: TextView? = null
    private var tradButton: TextView? = null

    /** 中缝工作台（仅分体形态存在） */
    private var wbComposing: TextView? = null
    private var wbGrid: LinearLayout? = null

    private var layoutSignature = ""
    private var building = false
    private var inputViewRef: View? = null

    private val repeatHandler = Handler(Looper.getMainLooper())
    private val prefs by lazy { getSharedPreferences("liana_layout", MODE_PRIVATE) }

    // ---- 生命周期 ----

    override fun onCreate() {
        super.onCreate()
        val dictFile = getFileStreamPath("base.ifd")
        if (!dictFile.exists()) {
            try {
                assets.open("base.ifd").use { input ->
                    dictFile.outputStream().use { input.copyTo(it) }
                }
            } catch (_: Exception) {
                // 词典缺失时回退内核内置词典
            }
        }
        val dictPath = if (dictFile.exists()) dictFile.absolutePath else null
        session = (dictPath?.let { LianaJni.newWithDict("pinyin", it) } ?: 0L)
            .takeIf { it != 0L } ?: LianaJni.new("pinyin")
        importUserLexicon()
    }

    override fun onDestroy() {
        repeatHandler.removeCallbacksAndMessages(null)
        saveUserLexicon()
        if (session != 0L) LianaJni.free(session)
        session = 0L
        super.onDestroy()
    }

    private fun importUserLexicon() {
        val f = getFileStreamPath("user_dict.tsv")
        if (f.exists() && session != 0L) {
            try {
                LianaJni.userImport(session, f.readText())
            } catch (_: Exception) {
            }
        }
    }

    private fun saveUserLexicon() {
        if (session == 0L) return
        try {
            LianaJni.userExport(session)?.let { getFileStreamPath("user_dict.tsv").writeText(it) }
        } catch (_: Exception) {
        }
    }

    // ---- 键盘 UI（程序化构建，无 XML 布局） ----

    override fun onCreateInputView(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(LianaTheme.BG)
        }

        // 候选栏（横向滚动）
        candidateStrip = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), dp(4), dp(8), dp(4))
        }
        val candidateScroll = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            addView(candidateStrip, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(40)))
        }
        root.addView(candidateScroll)

        // 键盘区：只换视图，不动 session / 候选 / 中英简繁（L1 L2）
        keyboardArea = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(keyboardArea, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dp(keyboardAreaHeightDp())))

        // 宽度变化（折叠 / 展开 / 分屏 / 旋转）→ 按签名重建
        root.addOnLayoutChangeListener { v, _, _, _, _, _, _, _, _ ->
            maybeRebuildKeyboard(v.width)
        }
        inputViewRef = root
        maybeRebuildKeyboard(0)
        return root
    }

    /** 单行槽高：可见键高 46 + 上下各 4dp 留白（触控热区仍 ≥ 46dp）。 */
    private fun slotHeightDp(): Float = FoldLayout.KEY_HEIGHT + 2 * ROW_INSET_DP

    private fun keyboardAreaHeightDp(): Float = 4 * slotHeightDp()

    private fun maybeRebuildKeyboard(widthPx: Int) {
        if (building) return
        val width = if (widthPx > 0) widthPx else resources.displayMetrics.widthPixels
        val density = resources.displayMetrics.density
        val widthDp = width / density
        if (widthDp <= 0f) return

        val remembered = if (prefs.contains(KEY_SOLO_PITCH)) prefs.getFloat(KEY_SOLO_PITCH, 0f) else null
        val layout = FoldLayout.derive(
            widthDp = widthDp,
            heightDp = resources.configuration.screenHeightDp.toFloat(),
            rememberedSoloPitch = remembered
        )
        if (layout.signature == layoutSignature) return
        layoutSignature = layout.signature
        if (layout.mode == FoldLayout.Mode.SOLO) {
            prefs.edit().putFloat(KEY_SOLO_PITCH, layout.pitchDp).apply()
        }

        building = true
        keyboardArea.removeAllViews()
        modeButton = null
        tradButton = null
        wbComposing = null
        wbGrid = null
        when (layout.mode) {
            FoldLayout.Mode.SOLO -> buildSolo(layout, widthDp)
            FoldLayout.Mode.SPLIT -> buildSplit(layout)
        }
        building = false
        renderCandidates()
    }

    // ---- 布局 A：单块（外屏 / 手机） ----

    private fun buildSolo(layout: FoldLayout, widthDp: Float) {
        val rows = listOf("qwertyuiop", "asdfghjkl", "zxcvbnm")
        val avail = widthDp - 2 * layout.marginDp
        val slot = dp(slotHeightDp()).toInt()

        rows.forEachIndexed { i, keys ->
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_HORIZONTAL
            }
            keys.forEach { ch ->
                row.addView(slotKey(ch.toString(), layout.pitchDp) { onLetter(ch) })
            }
            if (i == 2) {
                val used = keys.length * layout.pitchDp + keys.length * layout.gapDp
                row.addView(backspaceView(maxOf(layout.pitchDp, avail - used)))
            }
            keyboardArea.addView(row, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, slot))
        }

        keyboardArea.addView(buildSoloFnRow(layout, avail), LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, slot))
    }

    private fun buildSoloFnRow(layout: FoldLayout, avail: Float): LinearLayout {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_HORIZONTAL
        }
        val fnWidth = maxOf(48f, layout.pitchDp)
        val spaceWidth = maxOf(72f, avail - 5 * fnWidth - 5 * layout.gapDp)

        modeButton = slotKey("中", fnWidth) { onModeToggle() }
        tradButton = slotKey("简", fnWidth) { onTraditionalToggle() }
        row.addView(modeButton)
        row.addView(tradButton)
        row.addView(slotKey(",", fnWidth) { commitText(",") })
        row.addView(slotKey("空格", spaceWidth) { onSpace() })
        row.addView(slotKey(".", fnWidth) { commitText(".") })
        row.addView(slotKey("回车", fnWidth) { onEnter() })
        return row
    }

    // ---- 布局 B：左右分体 + 中缝工作台（内屏 / Pad） ----

    private fun buildSplit(layout: FoldLayout) {
        val rows = listOf("qwertyuiop", "asdfghjkl", "zxcvbnm")
        // 与既有实现一致的双手分配：10→5/5、9→5/4、7→4/3
        val mids = listOf(5, 5, 4)
        val clusterPx = dp(layout.clusterWidthDp).toInt()
        val slot = dp(slotHeightDp()).toInt()
        val gapPx = dp(layout.marginDp)

        val left = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.START
        }
        val right = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.END
        }

        rows.forEachIndexed { i, keys ->
            val mid = mids[i]
            val leftRow = clusterRow(layout, keys.take(mid).map(Char::toString), backspace = i == 2, alignEnd = false)
            val rightRow = clusterRow(layout, keys.drop(mid).map(Char::toString), backspace = i == 2, alignEnd = true)
            left.addView(leftRow, LinearLayout.LayoutParams(clusterPx, slot))
            right.addView(rightRow, LinearLayout.LayoutParams(clusterPx, slot))
        }

        // 功能行：中/简/，/空格 贴内侧；空格两侧各一颗，拇指互不越界
        val fnWidth = maxOf(48f, layout.pitchDp)
        val leftSpace = maxOf(64f, layout.clusterWidthDp - 3 * fnWidth - 3 * layout.gapDp)
        val rightSpace = maxOf(64f, layout.clusterWidthDp - 2 * fnWidth - 2 * layout.gapDp)

        val leftFn = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.START
        }
        modeButton = slotKey("中", fnWidth) { onModeToggle() }
        tradButton = slotKey("简", fnWidth) { onTraditionalToggle() }
        leftFn.addView(modeButton)
        leftFn.addView(tradButton)
        leftFn.addView(slotKey(",", fnWidth) { commitText(",") })
        leftFn.addView(slotKey("空格", leftSpace) { onSpace() })

        val rightFn = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
        }
        rightFn.addView(slotKey("空格", rightSpace) { onSpace() })
        rightFn.addView(slotKey(".", fnWidth) { commitText(".") })
        rightFn.addView(slotKey("回车", fnWidth) { onEnter() })

        left.addView(leftFn, LinearLayout.LayoutParams(clusterPx, slot))
        right.addView(rightFn, LinearLayout.LayoutParams(clusterPx, slot))

        val halves = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 0, 0, 0)
        }
        halves.addView(left, LinearLayout.LayoutParams(clusterPx, ViewGroup.LayoutParams.MATCH_PARENT))
        halves.addView(buildWorkbench(), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
        halves.addView(right, LinearLayout.LayoutParams(clusterPx, ViewGroup.LayoutParams.MATCH_PARENT))
        val lp = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        lp.setMargins(gapPx, 0, gapPx, 0)
        keyboardArea.addView(halves, lp)
    }

    private fun clusterRow(
        layout: FoldLayout,
        titles: List<String>,
        backspace: Boolean,
        alignEnd: Boolean
    ): LinearLayout {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = if (alignEnd) Gravity.END else Gravity.START
        }
        titles.forEach { t ->
            val ch = t.firstOrNull() ?: return@forEach
            row.addView(slotKey(t, layout.pitchDp) { onLetter(ch) })
        }
        if (backspace) {
            val used = titles.size * layout.pitchDp + titles.size * layout.gapDp
            row.addView(backspaceView(maxOf(layout.pitchDp, layout.clusterWidthDp - used)))
        }
        return row
    }

    // ---- 中缝工作台（候选网格 + 光标移动 + 组合串） ----

    private fun buildWorkbench(): LinearLayout {
        val gutter = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(10), dp(8), dp(10), dp(8))
        }

        val composing = TextView(this).apply {
            text = "中缝 · 候选与光标"
            textSize = 12f
            setTextColor(LianaTheme.SECONDARY)
            gravity = Gravity.CENTER
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        wbComposing = composing
        gutter.addView(composing, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dp(16)))

        // 候选网格：可竖向滚动，每个候选热区 ≥ 52dp
        val gridScroll = ScrollView(this).apply { isVerticalScrollBarEnabled = false }
        val grid = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        gridScroll.addView(grid, ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        wbGrid = grid
        gutter.addView(gridScroll, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        val cursorRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        cursorRow.addView(weightKey("←") { moveCursor(-1) },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
        cursorRow.addView(weightKey("→") { moveCursor(1) },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
        gutter.addView(cursorRow, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dp(34)))
        return gutter
    }

    private fun renderWorkbench() {
        val grid = wbGrid ?: return
        wbComposing?.text = if (composingText.isEmpty()) "中缝 · 候选与光标" else composingText
        grid.removeAllViews()

        val shown = candidates.take(MAX_CANDIDATES)
        if (shown.isEmpty()) {
            val hint = TextView(this).apply {
                text = "候选随输入出现在这里"
                textSize = 11f
                setTextColor(LianaTheme.SECONDARY)
                gravity = Gravity.CENTER
            }
            grid.addView(hint, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(52)))
            return
        }

        var index = 0
        while (index < shown.size) {
            val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            for (offset in 0..1) {
                val i = index + offset
                val lp = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f)
                lp.setMargins(dp(2), dp(2), dp(2), dp(2))
                if (i < shown.size) {
                    row.addView(workbenchCandidate(shown[i], i), lp)
                } else {
                    row.addView(View(this), lp)
                }
            }
            grid.addView(row, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(52)))
            index += 2
        }
    }

    private fun workbenchCandidate(text: String, index: Int): TextView {
        return baseKey(text).apply {
            textSize = LianaTheme.FONT_CANDIDATE
            background = GradientDrawable().apply {
                cornerRadius = dp(6).toFloat()
                setColor(LianaTheme.KEY_PRESSED)
            }
            setOnClickListener {
                haptic(HapticFeedbackConstants.LONG_PRESS)
                selectCandidate(index)
            }
        }
    }

    private fun moveCursor(delta: Int) {
        val ic = currentInputConnection ?: return
        val text = ic.getExtractedText(android.view.inputmethod.ExtractedTextRequest(), 0) ?: return
        val start = text.selectionStart
        if (start < 0) return
        val target = (start + delta).coerceAtLeast(0)
        ic.setSelection(target, target)
    }

    // ---- 按键视图工厂 ----

    /** 槽宽恒定 = pitch：键距在两种形态间不跳变。 */
    private fun slotKey(label: String, slotWidthDp: Float, onClick: () -> Unit): TextView {
        return baseKey(label).apply {
            val w = (dp(slotWidthDp) - 2 * dp(KEY_INSET_DP)).coerceAtLeast(dp(14))
            val lp = LinearLayout.LayoutParams(w, ViewGroup.LayoutParams.MATCH_PARENT)
            lp.setMargins(dp(KEY_INSET_DP), dp(ROW_INSET_DP), dp(KEY_INSET_DP), dp(ROW_INSET_DP))
            layoutParams = lp
            setOnClickListener {
                haptic(HapticFeedbackConstants.KEYBOARD_TAP)
                onClick()
            }
        }
    }

    private fun weightKey(label: String, onClick: () -> Unit): TextView {
        return baseKey(label).apply {
            setOnClickListener {
                haptic(HapticFeedbackConstants.KEYBOARD_TAP)
                onClick()
            }
        }
    }

    /** 退格键：点击退一码；长按连删（§3.3）；左滑整段清除。 */
    private fun backspaceView(slotWidthDp: Float): TextView {
        val swipeThreshold = dp(64)
        var downX = 0f
        var swiped = false
        return baseKey("⌫").apply {
            val w = (dp(slotWidthDp) - 2 * dp(KEY_INSET_DP)).coerceAtLeast(dp(14))
            val lp = LinearLayout.LayoutParams(w, ViewGroup.LayoutParams.MATCH_PARENT)
            lp.setMargins(dp(KEY_INSET_DP), dp(ROW_INSET_DP), dp(KEY_INSET_DP), dp(ROW_INSET_DP))
            layoutParams = lp

            val repeatRunnable = object : Runnable {
                override fun run() {
                    if (rawInput.isNotEmpty()) {
                        LianaJni.backspace(session)
                        refreshCandidates()
                    } else {
                        sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL)
                    }
                    repeatHandler.postDelayed(this, 65)
                }
            }
            setOnTouchListener { v, ev ->
                when (ev.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        downX = ev.x; swiped = false
                        v.isPressed = true
                        repeatHandler.postDelayed(repeatRunnable, 300)
                        true
                    }
                    MotionEvent.ACTION_MOVE -> {
                        if (!swiped && downX - ev.x > swipeThreshold) {
                            swiped = true
                            repeatHandler.removeCallbacks(repeatRunnable)
                            // 左滑 = 整段组合清除（退格版的 Esc）
                            LianaJni.clear(session)
                            v.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                            refreshCandidates()
                        }
                        true
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        v.isPressed = false
                        repeatHandler.removeCallbacks(repeatRunnable)
                        if (!swiped) {
                            v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                            onBackspace()
                        }
                        true
                    }
                    else -> false
                }
            }
        }
    }

    private fun baseKey(label: String): TextView {
        return TextView(this).apply {
            text = label
            gravity = Gravity.CENTER
            textSize = LianaTheme.FONT_KEY
            setTextColor(LianaTheme.TEXT)
            typeface = Typeface.DEFAULT_BOLD
            background = GradientDrawable().apply {
                cornerRadius = dp(8).toFloat()
                setColor(LianaTheme.KEY)
            }
        }
    }

    private fun haptic(constant: Int) {
        inputViewRef?.performHapticFeedback(constant)
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()
    private fun dp(v: Float): Int = (v * resources.displayMetrics.density).toInt()

    // ---- 按键行为（与 macOS 端行为约定一致） ----

    private fun onLetter(ch: Char) {
        if (session == 0L) return
        if (currentMode() == "en") {
            commitText(ch.toString())
            return
        }
        LianaJni.feed(session, ch.toString())
        refreshCandidates()
    }

    private fun onBackspace() {
        if (session == 0L) return
        if (rawInput.isNotEmpty()) {
            LianaJni.backspace(session)
            refreshCandidates()
        } else {
            sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL)
        }
    }

    private fun onSpace() {
        if (candidates.isNotEmpty()) {
            selectCandidate(0, strong = true)
        } else {
            commitText(" ")
        }
    }

    private fun onEnter() {
        if (rawInput.isNotEmpty()) {
            commitRaw()
        } else {
            sendDownUpKeyEvents(KeyEvent.KEYCODE_ENTER)
        }
    }

    private fun onModeToggle() {
        modeIdx = (modeIdx + 1) % MODES.size
        applyMode()
    }

    private fun onTraditionalToggle() {
        if (session == 0L) return
        val on = !LianaJni.traditional(session)
        LianaJni.setTraditional(session, on)
        tradButton?.text = if (on) "繁" else "简"
        refreshCandidates()
    }

    private fun applyMode() {
        if (session == 0L) return
        val mode = MODES[modeIdx]
        LianaJni.setMode(session, mode)
        LianaJni.clear(session)
        modeButton?.text = when (mode) {
            "pinyin" -> "中"
            "en" -> "EN"
            else -> mode
        }
        refreshCandidates()
    }

    private fun currentMode(): String = MODES[modeIdx]

    private fun selectCandidate(index: Int, strong: Boolean = false) {
        val text = LianaJni.select(session, index) ?: return
        commitText(text)
        // 上屏加强触觉：形成"上屏了"的身体确认（§3.1）
        haptic(HapticFeedbackConstants.LONG_PRESS)
        // 引擎可能留剩余缓冲，候选要立刻跟着变
        refreshCandidates()
    }

    private fun commitRaw() {
        val text = LianaJni.commitRaw(session) ?: return
        commitText(text)
        haptic(HapticFeedbackConstants.LONG_PRESS)
        refreshCandidates()
    }

    private fun commitText(text: String) {
        currentInputConnection?.commitText(text, 1)
    }

    // ---- 候选刷新（状态 → 渲染，两处入口共用） ----

    private fun refreshCandidates() {
        candidates = emptyList()
        rawInput = ""
        composingText = ""

        if (session != 0L) {
            val json = LianaJni.compositionJson(session)
            if (json != null) {
                try {
                    val obj = JSONObject(json)
                    val raw = obj.optString("raw", "")
                    if (raw.isNotEmpty()) {
                        rawInput = raw
                        val preedit = obj.optString("preedit", "")
                        composingText = if (preedit.isNotEmpty()) "$raw › $preedit" else raw
                        val arr = obj.optJSONArray("candidates")
                        if (arr != null) {
                            candidates = (0 until minOf(arr.length(), MAX_CANDIDATES)).mapNotNull { i ->
                                arr.optJSONObject(i)?.optString("text")?.takeIf { it.isNotEmpty() }
                            }
                        }
                    }
                } catch (_: Exception) {
                    // 畸形 JSON 不影响键盘可用性
                }
            }
        }
        renderCandidates()
    }

    private fun renderCandidates() {
        if (!::candidateStrip.isInitialized) return
        candidateStrip.removeAllViews()
        if (composingText.isNotEmpty()) {
            val composing = TextView(this).apply {
                text = composingText
                textSize = 14f
                setTextColor(LianaTheme.SECONDARY)
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(8), 0, dp(12), 0)
            }
            candidateStrip.addView(composing)
        }
        candidates.forEachIndexed { i, text ->
            candidateStrip.addView(candidateView(text, i))
        }
        renderWorkbench()
    }

    /** 候选条目：点击选中；上滑 ≥ 24dp 直接着该候选上屏（§3.2）。 */
    private fun candidateView(text: String, index: Int): TextView {
        val swipeUpThreshold = dp(24)
        var downY = 0f
        var swiped = false
        return TextView(this).apply {
            this.text = text
            textSize = LianaTheme.FONT_CANDIDATE
            setTextColor(LianaTheme.TEXT)
            typeface = Typeface.DEFAULT_BOLD
            background = GradientDrawable().apply {
                cornerRadius = dp(6).toFloat()
                setColor(LianaTheme.KEY_PRESSED)
            }
            gravity = Gravity.CENTER
            setPadding(dp(12), 0, dp(12), 0)
            val lp = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT)
            lp.setMargins(dp(3), 0, dp(3), 0)
            layoutParams = lp
            setOnTouchListener { v, ev ->
                when (ev.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        downY = ev.y; swiped = false
                        true
                    }
                    MotionEvent.ACTION_MOVE -> {
                        if (!swiped && downY - ev.y > swipeUpThreshold) {
                            swiped = true
                            selectCandidate(index)
                        }
                        true
                    }
                    MotionEvent.ACTION_UP -> {
                        if (!swiped) selectCandidate(index)
                        true
                    }
                    else -> false
                }
            }
        }
    }

    companion object {
        private const val MAX_CANDIDATES = 9
        private const val KEY_INSET_DP = 2f   // 槽位左右留白（槽宽 = pitch 时，可见键宽 = pitch - 4dp）
        private const val ROW_INSET_DP = 4f   // 槽位上下留白（可见键高 46dp）
        private const val KEY_SOLO_PITCH = "layout.pitchSolo"
        private val MODES = arrayOf("pinyin", "en")
    }
}
