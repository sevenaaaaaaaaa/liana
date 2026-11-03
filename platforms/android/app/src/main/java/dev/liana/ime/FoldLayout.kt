package dev.liana.ime

/**
 * 折叠屏布局策略（唯一事实源：docs/design/FOLDABLE-ADAPTATION.md §4）。
 *
 * 核心不变量：
 * - 键距由**外屏（窄屏）宽度**决定，内屏复用同一 dp 值，漂移上限 +10%；
 * - 键高 / 键距 / 行数 / 字符位置在两种形态下恒定；
 * - 屏宽多出来的部分只喂「中缝」工作台，绝不摊给按键。
 *
 * 纯策略类：不引任何 Android UI 依赖，便于单测与推理。
 */
data class FoldLayout(
    val mode: Mode,
    val pitchDp: Float,
    val gapDp: Float = GAP,
    val marginDp: Float = MARGIN,
    val keyHeightDp: Float = KEY_HEIGHT,
    val clusterWidthDp: Float,
    val gutterWidthDp: Float
) {

    enum class Mode { SOLO, SPLIT }

    /** 只有签名变化才重建视图。 */
    val signature: String
        get() = "${mode.name}-${pitchDp.toInt()}-${clusterWidthDp.toInt()}"

    companion object {
        const val GAP = 4f
        const val MARGIN = 4f
        const val KEY_HEIGHT = 46f
        const val MIN_PITCH = 34f
        const val MAX_SOLO_PITCH = 46f
        const val MAX_SPLIT_PITCH = 48f
        const val MIN_GUTTER = 56f
        const val SPLIT_MIN_WIDTH_DP = 600f
        const val SPLIT_MIN_HEIGHT_DP = 520f
        const val COLUMNS_PER_HALF = 5

        /** p_solo = clamp((W - 2·margin - 9·gap) / 10, 34, 46)。 */
        fun soloPitch(widthDp: Float): Float {
            val raw = (widthDp - 2 * MARGIN - 9 * GAP) / 10f
            return raw.coerceIn(MIN_PITCH, MAX_SOLO_PITCH)
        }

        fun derive(widthDp: Float, heightDp: Float, rememberedSoloPitch: Float?): FoldLayout {
            val split = widthDp >= SPLIT_MIN_WIDTH_DP && heightDp >= SPLIT_MIN_HEIGHT_DP
            if (!split) {
                return FoldLayout(
                    mode = Mode.SOLO,
                    pitchDp = soloPitch(widthDp),
                    clusterWidthDp = widthDp - 2 * MARGIN,
                    gutterWidthDp = 0f
                )
            }
            val base = rememberedSoloPitch ?: 44f
            val pitch = (base * 1.10f).coerceIn(MIN_PITCH, MAX_SPLIT_PITCH)
            val cluster = COLUMNS_PER_HALF * pitch + (COLUMNS_PER_HALF - 1) * GAP
            val gutter = maxOf(MIN_GUTTER, widthDp - 2 * cluster - 2 * MARGIN)
            return FoldLayout(
                mode = Mode.SPLIT,
                pitchDp = pitch,
                clusterWidthDp = cluster,
                gutterWidthDp = gutter
            )
        }
    }
}
