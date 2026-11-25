package dev.liana.ime

/**
 * Rust 内核的 JNI 绑定。所有会话句柄都是不透明 jlong，Kotlin 只透传不解析。
 * 垫片实现见 app/src/main/cpp/jni_shim.c（C，直调 liana.h）。
 */
object LianaJni {
    init {
        System.loadLibrary("liana_jni")
    }

    external fun nativeNew(mode: String): Long
    external fun nativeNewWithDict(mode: String, dictPath: String): Long
    external fun nativeFree(session: Long)
    external fun nativeFeed(session: Long, ch: String): Int
    external fun nativeBackspace(session: Long): Int
    external fun nativeClear(session: Long)
    external fun nativeSetMode(session: Long, mode: String): Int
    external fun nativeMode(session: Long): String?
    external fun nativeSetTraditional(session: Long, on: Int): Int
    external fun nativeTraditional(session: Long): Int
    external fun nativeCompositionJson(session: Long): String?
    external fun nativeSelect(session: Long, index: Int): String?
    external fun nativeCommitRaw(session: Long): String?
    external fun nativeRecordCommit(session: Long, text: String): Int
    external fun nativeUserExport(session: Long): String?
    external fun nativeUserImport(session: Long, tsv: String): Int
    external fun nativeVersion(): String

    /** 内核语言清单（JSON）。签入的 .so 未重建时该符号不存在，调用方必须能忍。 */
    external fun nativeLanguages(): String?

    fun new(mode: String): Long = nativeNew(mode)
    fun newWithDict(mode: String, dictPath: String): Long = nativeNewWithDict(mode, dictPath)
    fun free(session: Long) = nativeFree(session)
    fun feed(session: Long, ch: String): Boolean = nativeFeed(session, ch) == 1
    fun backspace(session: Long): Boolean = nativeBackspace(session) == 1
    fun clear(session: Long) = nativeClear(session)
    fun setMode(session: Long, mode: String): Boolean = nativeSetMode(session, mode) == 1
    fun mode(session: Long): String? = nativeMode(session)
    fun setTraditional(session: Long, on: Boolean) = nativeSetTraditional(session, if (on) 1 else 0)
    fun traditional(session: Long): Boolean = nativeTraditional(session) == 1
    fun compositionJson(session: Long): String? = nativeCompositionJson(session)
    fun select(session: Long, index: Int): String? = nativeSelect(session, index)
    fun commitRaw(session: Long): String? = nativeCommitRaw(session)
    fun recordCommit(session: Long, text: String) = nativeRecordCommit(session, text)
    fun userExport(session: Long): String? = nativeUserExport(session)
    fun userImport(session: Long, tsv: String): Boolean = nativeUserImport(session, tsv) >= 0
    fun version(): String = nativeVersion()

    /**
     * 语言清单。`.so` 未重建时 JNI 会抛 UnsatisfiedLinkError，这里吃掉返回 null，
     * 由 LanguageMenu.load() 回退到内置 9 项——菜单少了语言可以，崩不行。
     */
    fun languages(): String? = runCatching { nativeLanguages() }.getOrNull()
}