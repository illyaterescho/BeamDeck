import { useEffect, useRef, useState } from 'react'
import { Clipboard, CornerDownLeft, Delete, ExternalLink, Keyboard, X } from 'lucide-react'
import type { Action } from './model'
import type { ProjectorStatus } from './cinema'

const textStatus = {
  ready: 'Поле на проєкторі готове до введення.',
  keyboard_required: 'Увімкніть і виберіть «Клавіатура BeamDeck» у налаштуваннях Agent.',
  field_required: 'Поставте курсор у поле на проєкторі.',
  protected_field: 'Android позначив поле як захищене.',
}

export function RemoteKeyboard({ projector, demo, disabled, problem, run, close }: {
  projector?: ProjectorStatus; demo: boolean; disabled: boolean; problem?: string
  run: (action: Action) => Promise<boolean>; close: () => void
}) {
  const sheet = useRef<HTMLDialogElement>(null)
  const field = useRef<HTMLTextAreaElement>(null)
  const [draft, setDraft] = useState('')
  const [hint, setHint] = useState('')
  const ready = !disabled && (demo || projector?.keyboard === 'ready')
  const target = draft.trim()
  let url: URL | undefined
  try { url = new URL(target) } catch { /* Plain text is also accepted. */ }
  const canOpen = !disabled && projector?.canOpen && url && ['https:', 'http:'].includes(url.protocol) && !url.username && !url.password

  useEffect(() => {
    const dialog = sheet.current
    dialog?.showModal()
    return () => dialog?.close()
  }, [])

  async function paste() {
    try {
      if (!navigator.clipboard?.readText) throw new Error()
      const text = await navigator.clipboard.readText()
      if (text) setDraft(text.slice(0, 1500))
      field.current?.focus()
    } catch {
      field.current?.focus()
      setHint('Затисніть текстове поле та виберіть «Вставити» в меню iPhone. На Mac натисніть ⌘V.')
    }
  }

  async function send(action: 'text' | 'delete' | 'enter') {
    if (!ready || action === 'text' && draft.length === 0) return
    setHint('')
    const success = await run({ type: 'input', action, text: action === 'text' ? draft : '' })
    if (success) setHint(demo ? 'Демо прийняло команду.' : 'Запит передано активному полю Android.')
  }

  return <dialog className="keyboard-sheet" ref={sheet} aria-labelledby="keyboard-title" onCancel={event => { event.preventDefault(); close() }}
    onClick={event => { if (event.target === sheet.current) close() }}>
    <section>
      <header className="sheet-head"><div><Keyboard size={21} /><h2 id="keyboard-title">Клавіатура</h2></div>
        <button className="studio-icon" type="button" aria-label="Закрити клавіатуру" onClick={close}><X size={21} /></button></header>
      <label htmlFor="remote-text">{textStatus[projector?.keyboard ?? 'keyboard_required']}</label>
      <textarea id="remote-text" ref={field} rows={3} autoCapitalize="off" autoCorrect="off" spellCheck={false}
        placeholder="Текст або посилання" maxLength={1500} value={draft} onChange={event => { setDraft(event.target.value); setHint('') }} />
      <div className="sheet-buttons">
        <button className="secondary" onClick={() => void paste()}><Clipboard size={17} /> Вставити</button>
        <button className="primary" disabled={!ready || !draft} onClick={() => void send('text')}>Надіслати в поле</button>
      </div>
      <div className="sheet-buttons">
        <button className="secondary" disabled={!ready} aria-label="Видалити символ" onClick={() => void send('delete')}><Delete size={18} /></button>
        <button className="secondary" disabled={!ready} onClick={() => void send('enter')}><CornerDownLeft size={16} /> Enter</button>
        <button className="secondary" disabled={!canOpen} onClick={() => void run({ type: 'open', destination: 'url', value: url?.href ?? target })}>
          <ExternalLink size={16} /> Відкрити URL
        </button>
      </div>
      {problem ? <p className="error" role="alert">{problem}</p> : hint && <p className="hint" role="status">{hint}</p>}
    </section>
  </dialog>
}
