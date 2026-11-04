package dev.liana.ime

import android.content.ComponentName
import android.content.Intent
import android.graphics.Typeface
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.app.Activity

/**
 * 首次安装引导页。
 *
 * Android 的输入法必须由用户手动「启用」再「设为当前键盘」，这两步没有 API 能替用户做，
 * 所以安装完至少要给一个能点的入口：以前 App 只有 Service、没有 Activity，桌面既没图标，
 * 键盘设置里的「设置」还指向 Service（点了没反应），用户只能自己去系统设置里翻。
 */
class SetupActivity : Activity() {

    private lateinit var statusText: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "松萝输入法"

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(32), dp(24), dp(24))
        }

        root.addView(TextView(this).apply {
            text = "松萝输入法"
            textSize = 26f
            setTypeface(Typeface.DEFAULT, Typeface.BOLD)
        })

        root.addView(TextView(this).apply {
            text = "键盘不会自动出现，需要两步（系统强制要求手动操作）："
            textSize = 15f
            setPadding(0, dp(16), 0, dp(8))
        })

        root.addView(TextView(this).apply {
            text = "① 启用：系统设置 → 系统 → 语言和输入法 → 屏幕键盘 → 启用「松萝输入法」\n" +
                "② 设为当前：点下面的「选择输入法」→「松萝输入法」"
            textSize = 15f
            lineSpacing(dp(4).toFloat(), 1f)
            setPadding(0, 0, 0, dp(20))
        })

        statusText = TextView(this).apply {
            textSize = 15f
            setTypeface(Typeface.DEFAULT, Typeface.BOLD)
            setPadding(0, 0, 0, dp(20))
        }
        root.addView(statusText)

        root.addView(button("① 打开键盘设置") {
            startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
        })

        root.addView(button("② 选择输入法") {
            val imm = getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager
            imm.showInputMethodPicker()
        })

        setContentView(ScrollView(this).apply { addView(root) })
    }

    override fun onResume() {
        super.onResume()
        // 回到本页时刷新状态：用户可能刚从系统设置里启用完回来
        statusText.text = if (isOurImeEnabled()) "✓ 已启用，现在可以去任意输入框切到「松萝输入法」了" else "✗ 尚未启用"
    }

    private fun isOurImeEnabled(): Boolean {
        val imm = getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager
        return imm.enabledInputMethodList.any { it.packageName == packageName }
    }

    private fun button(label: String, onClick: () -> Unit): Button =
        Button(this).apply {
            text = label
            textSize = 16f
            setOnClickListener { onClick() }
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { bottomMargin = dp(12) }
        }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
