package ua.beamdeck.agent

import android.inputmethodservice.InputMethodService
import android.text.InputType
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.TextView

class BeamKeyboard : InputMethodService() {
    override fun onStartInput(info: EditorInfo?, restarting: Boolean) {
        super.onStartInput(info, restarting)
        current = this
    }

    override fun onFinishInput() {
        if (current === this) current = null
        super.onFinishInput()
    }

    override fun onDestroy() {
        if (current === this) current = null
        super.onDestroy()
    }

    override fun onCreateInputView(): View = TextView(this).apply {
        text = "BeamDeck · Введіть або вставте текст на телефоні"
        setTextColor(0xfffaf6ff.toInt())
        setBackgroundColor(0xff252132.toInt())
        setPadding(28, 20, 28, 20)
        textSize = 16f
    }

    internal fun reason(): String? {
        val editor = currentInputEditorInfo ?: return "field_required"
        val type = editor.inputType
        val kind = type and InputType.TYPE_MASK_CLASS
        val variation = type and InputType.TYPE_MASK_VARIATION
        if (kind == InputType.TYPE_NULL || currentInputConnection == null) return "field_required"
        if (kind == InputType.TYPE_CLASS_TEXT && variation in listOf(
            InputType.TYPE_TEXT_VARIATION_PASSWORD, InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
        ) || kind == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD) {
            return "protected_field"
        }
        return null
    }

    internal fun input(action: String, text: String): ActionResult {
        reason()?.let { throw ApiProblem(409, it) }
        val connection = currentInputConnection ?: throw ApiProblem(409, "field_required")
        val accepted = when (action) {
            "text" -> connection.commitText(text, 1)
            "delete" -> sendKey(KeyEvent.KEYCODE_DEL)
            "enter" -> {
                val editor = currentInputEditorInfo
                val editorAction = editor.imeOptions and EditorInfo.IME_MASK_ACTION
                if (editorAction > EditorInfo.IME_ACTION_NONE &&
                    editor.imeOptions and EditorInfo.IME_FLAG_NO_ENTER_ACTION == 0
                ) connection.performEditorAction(editorAction) else sendKey(KeyEvent.KEYCODE_ENTER)
            }
            else -> throw ApiProblem(400, "bad_request")
        }
        if (!accepted) throw ApiProblem(409, "rejected")
        return ActionResult("submitted", "input_submitted")
    }

    private fun sendKey(code: Int): Boolean {
        val connection = currentInputConnection ?: return false
        val down = connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
        val up = connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
        return down && up
    }

    companion object {
        internal var current: BeamKeyboard? = null
            private set
    }
}
