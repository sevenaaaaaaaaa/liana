package dev.liana.ime

import org.json.JSONArray

/** 内核注册表里的一门输入方案（`liana_languages()` 的一项）。 */
data class LianaLanguage(val id: String, val label: String, val policy: String)

/**
 * 菜单语言的唯一来源是内核注册表：`LianaJni.languages()` → `liana_languages()`。
 *
 * 这里只做解析、回退、顺序和按键短名。以前 `MODES = arrayOf("pinyin", "en")` 写死两项，
 * 内核加了 ja/ko/es 之后 Android 菜单跟不上了；现在内核多一门语言，这里不用改。
 */
object LanguageMenu {
    /** 内核符号缺失（签入的 .so 未重建）或 JSON 坏掉时的兜底：与 builtin_languages() 的 9 项一致。 */
    val fallback: List<LianaLanguage> = listOf(
        LianaLanguage("pinyin", "拼音", "ascii"),
        LianaLanguage("flypy", "小鹤双拼", "ascii"),
        LianaLanguage("mspy", "微软双拼", "ascii"),
        LianaLanguage("zrm", "自然码", "ascii"),
        LianaLanguage("emoji", "表情", "ascii"),
        LianaLanguage("en", "English", "ascii"),
        LianaLanguage("es", "Español", "unicode"),
        LianaLanguage("ja", "日本語", "ascii"),
        LianaLanguage("ko", "한국어", "ascii"),
    )

    /**
     * 解析 `[{"id","label","policy"}]`。
     * 缺 id 的项丢弃、重复 id 保留第一个、缺 label 用 id 顶、坏输入返回空列表。
     */
    fun parse(json: String?): List<LianaLanguage> {
        if (json.isNullOrBlank()) return emptyList()
        val rows = try {
            JSONArray(json)
        } catch (_: Exception) {
            return emptyList()
        }
        val seen = HashSet<String>()
        val out = ArrayList<LianaLanguage>(rows.length())
        for (i in 0 until rows.length()) {
            val row = rows.optJSONObject(i) ?: continue
            val id = row.optString("id").trim()
            if (id.isEmpty() || !seen.add(id)) continue
            val label = row.optString("label").trim().ifEmpty { id }
            out.add(LianaLanguage(id, label, row.optString("policy")))
        }
        return out
    }

    /** 内核优先、回退兜底。 */
    fun load(json: String?): List<LianaLanguage> = parse(json).ifEmpty { fallback }

    /** 菜单顺序：内核顺序在前，平台自有方案殿后，重复 id 去掉。 */
    fun order(kernel: List<LianaLanguage>, platformIds: List<String>): List<String> {
        val seen = LinkedHashSet<String>()
        kernel.forEach { seen.add(it.id) }
        platformIds.forEach { seen.add(it) }
        return seen.toList()
    }

    /** 当前 id 的下一项（循环切语言）；清单为空时原样返回，不许崩。 */
    fun nextId(ids: List<String>, current: String): String {
        if (ids.isEmpty()) return current
        val index = ids.indexOf(current)
        return ids[(index + 1) % ids.size]
    }

    /** 模式键上的一两个字：功能键 12sp，放不下全名。 */
    fun badge(id: String): String = when (id) {
        "pinyin" -> "中"
        "flypy" -> "鹤"
        "mspy" -> "微"
        "zrm" -> "自"
        "en" -> "EN"
        "ja" -> "あ"
        "ko" -> "한"
        "es" -> "ES"
        "emoji" -> "表"
        "t9" -> "九"
        "wubi" -> "五"
        "handwriting" -> "手"
        else -> id.take(2).uppercase()
    }
}
