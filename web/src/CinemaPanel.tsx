import { useEffect, useState } from 'react'
import { AudioLines, Download, Film, FolderOpen, Pause, Play, RotateCcw, Save, Upload } from 'lucide-react'
import { baseCinema, grades } from './cinema'
import type { CinemaSettings } from './cinema'
import { identityGeometry, validQuad } from './geometry'
import type { Geometry } from './geometry'
import type { Action, Status } from './model'

const grading = [
  ['contrast', 'Контраст', -50, 50], ['saturation', 'Насиченість', -100, 100],
  ['warmth', 'Температура', -100, 100], ['shadow', 'Підняття тіней', 0, 100],
  ['gamma', 'Гама', -50, 50], ['smoothing', 'Просторове згладжування', 0, 100],
] as const
const subtitles = [
  ['captionSize', 'Розмір', 12, 72], ['captionPosition', 'Відступ від низу', 2, 40],
  ['captionDelay', 'Затримка, мс', -5000, 5000],
] as const

function Slider({ label, min, max, level, update, step = 1 }: {
  label: string; min: number; max: number; level: number; update: (level: number) => void; step?: number
}) {
  return <label className="effect-slider"><span>{label}<output>{level}</output></span>
    <input className="range" type="range" min={min} max={max} step={step} value={level} onChange={event => update(Number(event.target.value))}
      style={{ '--progress': (100 * (level - min) / (max - min)) + '%' } as React.CSSProperties} />
  </label>
}

function Switch({ label, checked, change, disabled }: { label: string; checked: boolean; change: (value: boolean) => void; disabled?: boolean }) {
  return <label className="toggle-line"><span>{label}</span><input type="checkbox" disabled={disabled} checked={checked} onChange={event => change(event.target.checked)} /></label>
}

export function CinemaPanel({ status, draft, setDraft, connected, busy, run, canOpen }: {
  status: Status; draft: CinemaSettings; setDraft: (settings: CinemaSettings) => void
  connected: boolean; busy: boolean; run: (action: Action) => Promise<boolean>; canOpen: boolean
}) {
  const [tab, setTab] = useState<'image' | 'audio' | 'subtitles'>('image')
  const [saved, setSaved] = useState(false)
  const [compareDirty, setCompareDirty] = useState(false)
  const player = status.player
  const active = connected && status.projector?.display === 'player' && player?.ready
  const canSave = connected && Boolean(status.cinema) && !busy
  const imageDisabled = Boolean((active && !player.effects) || status.device.api < 33)

  function update(next: CinemaSettings) {
    setDraft(next)
    setSaved(false)
  }

  useEffect(() => {
    if (!compareDirty || !active || !player?.effects || !canSave) return
    const timer = window.setTimeout(() => {
      setCompareDirty(false)
      void run({ type: 'cinema', settings: { ...(status.cinema ?? baseCinema), split: draft.split } })
    }, 220)
    return () => window.clearTimeout(timer)
  }, [compareDirty, draft.split, active, player?.effects, canSave, run, status.cinema])

  return <div className="player-layout">
    <section className="studio-section player-intro">
      <span className="studio-feature"><Film size={27} /></span>
      <h2>Плеєр BeamDeck</h2>
      <p>Відкрийте плеєр і виберіть локальний відеофайл на проєкторі. Сітка, кольори й звук налаштовуються з телефона.</p>
      {active && <p className="studio-status"><span />{player.fps ? player.fps + ' кадрів/с' : 'Відеофайл відкрито'}
        {player.reduced ? ' · Спрощена обробка' : ''}</p>}
      <button className="primary" disabled={!canOpen} onClick={() => void run({ type: 'open', destination: 'player', value: '' })}>
        <FolderOpen size={19} /> Відкрити плеєр
      </button>
      <button className="secondary" disabled={!active || busy} onClick={() => void run({ type: 'playback' })}>
        {status.projector?.playing ? <Pause size={17} /> : <Play size={17} />}{status.projector?.playing ? 'Пауза' : 'Відтворити'}
      </button>
      <Switch label="Економний режим" checked={draft.lowPower} change={value => update({ ...draft, lowPower: value })} />
    </section>
    <section className="studio-section player-settings">
      <nav className="studio-tabs" aria-label="Ефекти плеєра">
        <button aria-current={tab === 'image' ? 'page' : undefined} onClick={() => setTab('image')}>Зображення</button>
        <button aria-current={tab === 'audio' ? 'page' : undefined} onClick={() => setTab('audio')}>Звук</button>
        <button aria-current={tab === 'subtitles' ? 'page' : undefined} onClick={() => setTab('subtitles')}>Субтитри</button>
      </nav>
      {tab === 'image' && <>
        <p className="hint">{active ? (player.effects ? 'GPU-ефекти доступні для цього відео.' : 'Шейдери недоступні на цьому пристрої.') :
          'Параметри зображення діють під час відтворення в BeamDeck на Android 13+.'}</p>
        <Switch label="Колір і тон" checked={draft.enabled} disabled={imageDisabled} change={enabled => update({ ...draft, enabled })} />
        <Switch label="Адаптивні тіні" checked={draft.adaptive} disabled={imageDisabled || draft.lowPower}
          change={adaptive => update({ ...draft, adaptive })} />
        {active && player.sceneBrightness != null && <p className="hint">Середня яскравість кадру · {player.sceneBrightness}%</p>}
        <div className="studio-pair grades">{grades.map(({ title, ...grade }) => <button key={grade.preset}
          aria-pressed={draft.preset === grade.preset} disabled={imageDisabled} onClick={() => update({ ...draft, ...grade, enabled: true })}>{title}</button>)}</div>
        <fieldset disabled={imageDisabled}>
          {grading.map(([key, label, min, max]) => <Slider key={key} label={label} min={min} max={max} level={draft[key]}
            update={level => update({ ...draft, [key]: level, preset: 'custom' })} />)}
          <div className="compare-control"><Slider label="Поділ оригіналу й обробки" min={0} max={100} level={draft.split}
            update={split => { update({ ...draft, split }); setCompareDirty(true) }} />
            <div><span>Обробка</span><span>Оригінал</span></div></div>
        </fieldset>
      </>}
      {tab === 'audio' && <>
        <p className="hint"><AudioLines size={15} /> {active ? (player.audio ? 'Еквалайзер під’єднаний до цієї медіасесії.' : 'Еквалайзер недоступний для цього файлу.') :
          'Підсилення діалогів через частоти голосу застосовується у плеєрі BeamDeck.'}</p>
        <fieldset disabled={active && !player.audio}><Slider label="Підсилення діалогів" min={0} max={100} level={draft.dialogue}
          update={dialogue => update({ ...draft, dialogue })} /></fieldset>
        <Switch label="Нічний режим" checked={draft.compression > 0} disabled={status.device.api < 28 || active && !player.compression}
          change={enabled => update({ ...draft, compression: enabled ? 65 : 0 })} />
        <fieldset disabled={status.device.api < 28 || active && !player.compression}>
          <Slider label="Компресія динаміки" min={0} max={100} level={draft.compression}
            update={compression => update({ ...draft, compression })} />
        </fieldset>
        {active && !player.compression && <p className="hint">Android не надав компресор для цього аудіосеансу.</p>}
      </>}
      {tab === 'subtitles' && <>
        <p className="hint">Виберіть SRT або WebVTT кнопкою «Субтитри» на екрані проєктора.</p>
        <Switch label="Показувати субтитри" checked={draft.captions} change={captions => update({ ...draft, captions })} />
        {subtitles.map(([key, label, min, max]) => <Slider key={key} label={label} min={min} max={max} step={key === 'captionDelay' ? 100 : 1}
          level={draft[key]} update={level => update({ ...draft, [key]: level })} />)}
        <label className="caption-select"><span>Колір</span><select value={draft.captionColor}
          onChange={event => update({ ...draft, captionColor: event.target.value as CinemaSettings['captionColor'] })}>
          <option value="white">Білий</option><option value="ivory">Теплий білий</option><option value="yellow">Жовтий</option></select></label>
        <Switch label="Темне тло" checked={draft.captionBackground} change={captionBackground => update({ ...draft, captionBackground })} />
      </>}
      <div className="sheet-buttons">
        <button className="secondary" onClick={() => update(baseCinema)}><RotateCcw size={16} /> Скинути</button>
        <button className="primary" disabled={!canSave} onClick={async () => setSaved(await run({ type: 'cinema', settings: draft }))}>
          <Save size={17} /> Зберегти в Agent
        </button>
      </div>
      {saved && <p className="hint" role="status">{active ? 'Agent зберіг параметри поточного плеєра.' : 'Agent зберіг параметри для наступного відтворення.'}</p>}
    </section>
  </div>
}

type Profile = { id: string; name: string; geometry: Geometry; cinema: CinemaSettings; volume: number; timer: number }
const storageKey = 'beamdeck.cinema.profiles.v1'
const presetProfiles: Profile[] = [
  { id: 'dark-fantasy', name: 'Dark Fantasy', geometry: identityGeometry, cinema: { ...baseCinema, preset: 'cinema', enabled: true, shadow: 45, warmth: 9 }, volume: 35, timer: 0 },
  { id: 'animation', name: 'Animation', geometry: identityGeometry, cinema: { ...baseCinema, preset: 'vivid', enabled: true, saturation: 21 }, volume: 31, timer: 0 },
  { id: 'action', name: 'Action', geometry: identityGeometry, cinema: { ...baseCinema, enabled: true, contrast: 15, dialogue: 25 }, volume: 41, timer: 0 },
  { id: 'classic', name: 'Classic Cinema', geometry: identityGeometry, cinema: { ...baseCinema, enabled: true, warmth: 17, saturation: -20 }, volume: 33, timer: 0 },
]

function integer(value: unknown, min: number, max: number): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value >= min && value <= max
}

function safeProfile(value: unknown): value is Profile {
  if (!value || typeof value !== 'object') return false
  const p = value as Profile
  const s = p.cinema
  return typeof p.id === 'string' && p.id.length <= 60 && typeof p.name === 'string' && p.name.trim().length > 0 && p.name.length <= 44 &&
    validQuad(p.geometry?.corners) && ['manual','auto'].includes(p.geometry.mode) && integer(p.volume,0,100) && integer(p.timer,0,180) &&
    Boolean(s) && ['natural', 'cinema', 'vivid', 'custom'].includes(s.preset) &&
    ['white', 'ivory', 'yellow'].includes(s.captionColor) && ['enabled','captions','captionBackground','lowPower','adaptive'].every(key =>
      typeof s[key as keyof CinemaSettings] === 'boolean') &&
    [...grading, ...subtitles, ['split','',0,100], ['dialogue','',0,100], ['compression','',0,100]].every(([key, , min, max]) =>
      integer(s[key as keyof CinemaSettings], Number(min), Number(max)))
}

function initialProfiles(): Profile[] {
  try {
    const value = JSON.parse(localStorage.getItem(storageKey) ?? 'null')
    if (Array.isArray(value) && value.length <= 16 && value.every(safeProfile)) return value
  } catch { /* Local profiles are optional. */ }
  return presetProfiles
}

function nextId() { return Date.now().toString(36) + Math.random().toString(36).slice(2, 10) }

export function ProfilesPanel({ geometry, cinema, applyProfile, status, connected, busy, canOpen, run }: {
  geometry: Geometry; cinema: CinemaSettings; applyProfile: (geometry: Geometry, settings: CinemaSettings) => Promise<boolean>
  status: Status; connected: boolean; busy: boolean; canOpen: boolean; run: (action: Action) => Promise<boolean>
}) {
  const [profiles, setProfiles] = useState(initialProfiles)
  const [selected, setSelected] = useState(profiles[0]?.id ?? '')
  const [name, setName] = useState(profiles[0]?.name ?? '')
  const [volume, setVolume] = useState(profiles[0]?.volume ?? 35)
  const [timer, setTimer] = useState(profiles[0]?.timer ?? 0)
  const [message, setMessage] = useState('')
  const [loading, setLoading] = useState(false)
  const active = profiles.find(profile => profile.id === selected)

  function select(profile?: Profile) {
    setSelected(profile?.id ?? '')
    setName(profile?.name ?? '')
    setVolume(profile?.volume ?? 35)
    setTimer(profile?.timer ?? 0)
    setMessage('')
  }

  function persist(next: Profile[]) {
    try {
      localStorage.setItem(storageKey, JSON.stringify(next))
      setProfiles(next)
      return true
    } catch {
      setMessage('Не вдалося записати профіль у сховище браузера.')
      return false
    }
  }

  function store(copy: boolean, overwriteCurrent = false) {
    const nameToSave = name.trim().slice(0, 44)
    if (!nameToSave || (!active || copy) && profiles.length >= 16) return
    const profile: Profile = { id: !copy && active ? active.id : nextId(), name: nameToSave, volume, timer,
      geometry: !overwriteCurrent && active ? active.geometry : geometry,
      cinema: !overwriteCurrent && active ? active.cinema : cinema }
    const next = !copy && active ? profiles.map(item => item.id === active.id ? profile : item) : [...profiles, profile]
    if (persist(next)) { select(profile); setMessage('Профіль збережено у браузері.') }
  }

  function backup() {
    const url = URL.createObjectURL(new Blob([JSON.stringify({ version: 1, profiles }, null, 2)], { type: 'application/json' }))
    const link = document.createElement('a')
    link.href = url
    link.download = 'beamdeck-profiles.json'
    link.click()
    window.setTimeout(() => URL.revokeObjectURL(url), 3000)
  }

  async function restore(file?: File) {
    if (!file) return
    try {
      if (file.size > 150000) throw new Error()
      const data = JSON.parse(await file.text())
      if (data.version !== 1 || !Array.isArray(data.profiles) || !data.profiles.length ||
        data.profiles.length > 16 || !data.profiles.every(safeProfile)) throw new Error()
      const next: Profile[] = data.profiles.map((profile: Profile) => ({ ...profile, id: nextId() }))
      const room = 16 - profiles.length
      if (next.length > room) { setMessage('Звільніть місце. Браузер зберігає до 16 профілів.'); return }
      if (persist([...profiles, ...next])) { select(next[0]); setMessage('Профілі імпортовано.') }
    } catch { setMessage('Виберіть чинний JSON-файл профілів BeamDeck.') }
  }

  async function apply(start: boolean) {
    if (!active) return
    setLoading(true)
    setMessage('')
    try {
      if (!(await applyProfile(active.geometry, active.cinema))) return
      if (start) {
        const { min, max } = status.volume
        if (!(await run({ type: 'volume', level: min + Math.round((max - min) * active.volume / 100) }))) return
        if (!(await run({ type: 'open', destination: 'player', value: '' }))) return
        if (active.timer && !(await run({ type: 'sleep', minutes: active.timer }))) return
      }
      setMessage(start ? 'Agent прийняв профіль і запит на відкриття плеєра.' : 'Agent зберіг геометрію й параметри профілю.')
    } finally { setLoading(false) }
  }

  return <div className="profile-layout">
    <section className="studio-section">
      <h2>Профілі</h2>
      <div className="profile-list">{profiles.map(profile => <button key={profile.id} aria-pressed={selected === profile.id}
        onClick={() => select(profile)}>{profile.name}</button>)}</div>
      <button className="secondary" disabled={profiles.length >= 16} onClick={() => select()}>Новий профіль</button>
      <div className="sheet-buttons">
        <button className="secondary" onClick={backup}><Download size={16} /> Експорт</button>
        <label className="secondary file-button"><Upload size={16} /> Імпорт<input type="file" accept=".json,application/json"
          onChange={event => { void restore(event.target.files?.[0]); event.currentTarget.value = '' }} /></label>
      </div>
    </section>
    <section className="studio-section feature-form">
      <h2>{active ? 'Параметри профілю' : 'Новий профіль'}</h2>
      <label htmlFor="profile-name">Назва</label>
      <input id="profile-name" type="text" maxLength={44} value={name} onChange={event => setName(event.target.value)} />
      <Slider label="Гучність кінорежиму" min={0} max={100} level={volume} update={setVolume} />
      <label htmlFor="profile-timer">Таймер сну</label>
      <select id="profile-timer" value={timer} onChange={event => setTimer(Number(event.target.value))}>
        {[...new Set([0,15,30,60,90,timer])].sort((a,b) => a-b).map(time => <option key={time} value={time}>{time ? time + ' хв' : 'Вимкнено'}</option>)}
      </select>
      <div className="sheet-buttons">
        <button className="secondary" disabled={!name.trim()} onClick={() => store(false)}>Зберегти</button>
        <button className="secondary" disabled={!name.trim()} onClick={() => store(false, true)}>Записати поточні налаштування</button>
        {active && <button className="secondary" disabled={!name.trim() || profiles.length >= 16} onClick={() => store(true)}>Копіювати</button>}
      </div>
      {active && <div className="sheet-buttons">
        <button className="secondary" disabled={!connected || busy || loading} onClick={() => void apply(false)}>Застосувати</button>
        <button className="primary" disabled={!canOpen || busy || loading || !status.capabilities.volume.available ||
          Boolean(active.timer && !status.capabilities.sleep.available)} onClick={() => void apply(true)}>Відкрити в кінорежимі</button>
        <button className="text-button" onClick={() => { if (persist(profiles.filter(profile => profile.id !== selected))) select() }}>Видалити</button>
      </div>}
      {message && <p className="hint" role="status">{message}</p>}
    </section>
  </div>
}
