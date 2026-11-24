import { GeometryStudio } from './GeometryStudio'
import { RemoteKeyboard } from './RemoteKeyboard'
import { useEffect, useRef, useState } from 'react'
import type { FormEvent, PointerEvent, ReactNode } from 'react'
import {
  ArrowDown, ArrowLeft, ArrowRight, ArrowUp, ArrowUpRight, AudioLines, ChevronRight,
  CircleHelp, Clapperboard, Clock3, Compass, Film, FolderClosed, Gamepad2, Grid2X2, House,
  Frame, Keyboard, LoaderCircle, Minus, Moon, MousePointer2, Pause, Play, Plus, Projector, Radio, ScanLine, Settings2,
  SkipBack, SkipForward, Star, TvMinimalPlay, Undo2, Volume2, VolumeX, Wifi, WifiOff, X,
} from 'lucide-react'
import { agentAddress, AgentError, explain, initialDemo } from './agent'
import { unavailable, volumePercent } from './model'
import type { Action, CapabilityKey, Command, LaunchableApp, Screen, Status } from './model'
import { useAgent } from './useAgent'

const tabs = [
  { id: 'remote', label: 'Пульт', icon: Gamepad2 },
  { id: 'geometry', label: 'Екран', icon: Frame },
  { id: 'apps', label: 'Програми', icon: Grid2X2 },
  { id: 'scenes', label: 'Сцени', icon: Clapperboard },
  { id: 'settings', label: 'Налаштування', icon: Settings2 },
] as const
const directions = [
  { command: 'up', label: 'Вгору', icon: ArrowUp },
  { command: 'left', label: 'Ліворуч', icon: ArrowLeft },
  { command: 'right', label: 'Праворуч', icon: ArrowRight },
  { command: 'down', label: 'Вниз', icon: ArrowDown },
] as const
const simulatedCommands: Partial<Record<Command, string>> = {
  back: 'Назад', home: 'Додому', up: 'Вгору', down: 'Вниз',
  left: 'Ліворуч', right: 'Праворуч', ok: 'OK', previous: 'Попередній', next: 'Наступний',
}
const sleepOptions = [15, 30, 60, 90]
const sleepOutcomes = {
  idle: 'Пауза й вимкнення звуку за таймером.',
  scheduled: 'Пауза та вимкнення звуку після відліку.',
  submitted: 'Звук вимкнено, запит на паузу передано плеєру.',
  completed: 'Таймер вимкнув звук.',
  partial: 'Таймер виконав лише частину дій.',
  failed: 'Таймер не зміг призупинити відтворення або вимкнути звук.',
}

function read<T>(key: string, fallback: T): T {
  try {
    const value = localStorage.getItem('beamdeck.' + key)
    return value === null ? fallback : JSON.parse(value) as T
  } catch {
    return fallback
  }
}

function save(key: string, value: unknown) {
  try { localStorage.setItem('beamdeck.' + key, JSON.stringify(value)) } catch { /* private browsing */ }
}

function Mark() {
  return <span className="mark" aria-hidden="true"><span /><span /><span /></span>
}

function Nav({ screen, onChange }: { screen: Screen; onChange: (screen: Screen) => void }) {
  return <nav className="nav" aria-label="Розділи BeamDeck">
    {tabs.map(({ id, label, icon: Icon }) =>
      <button key={id} className={id === screen ? 'active' : ''} aria-current={id === screen ? 'page' : undefined} onClick={() => onChange(id)}>
        <Icon size={19} /><span>{label}</span>
      </button>,
    )}
  </nav>
}

function IconButton({ label, children, disabled, className = '', onClick, pressed }: {
  label: string; children: ReactNode; disabled?: boolean; className?: string;
  onClick: () => void; pressed?: boolean;
}) {
  return <button type="button" className={'key ' + className} aria-label={label} title={label}
    aria-pressed={pressed} disabled={disabled} onClick={onClick}>{children}</button>
}

function AddressForm() {
  const [address, setAddress] = useState('')
  const [error, setError] = useState('')
  function submit(event: FormEvent) {
    event.preventDefault()
    const url = agentAddress(address)
    if (!url) {
      setError('Введіть локальну IPv4-адресу та порт з екрана Agent.')
      return
    }
    location.assign(url.href)
  }
  return <form className="address-form" onSubmit={submit}>
    <label htmlFor="agent-address">IP-адреса та порт</label>
    <div className="inline-form">
      <input id="agent-address" type="text" autoCapitalize="none" spellCheck={false} placeholder="192.168.1.24:8765"
        value={address} onChange={event => { setAddress(event.target.value); setError('') }} required maxLength={32} />
      <button className="secondary" type="submit" aria-label="Відкрити адресу"><ArrowRight size={20} /></button>
    </div>
    {error && <p className="error" role="alert">{error}</p>}
  </form>
}

function Connect({ loading, detail, onPair, onDemo, onRetry }: {
  loading: boolean; detail: string; onPair: (pin: string) => Promise<void>; onDemo: () => void; onRetry: () => void;
}) {
  const [pin, setPin] = useState('')
  const [pending, setPending] = useState(false)
  const [error, setError] = useState('')
  const canPair = !detail
  async function submit(event: FormEvent) {
    event.preventDefault()
    if (!/^\d{6}$/.test(pin) || pending) return
    setPending(true)
    setError('')
    try { await onPair(pin) } catch (problem) { setError(explain(problem)) } finally { setPending(false) }
  }
  return <main className="connect-main">
    <div className="connect-card glass">
      <span className="device-icon connect-icon"><Projector size={30} /></span>
      <h1>Підключення</h1>
      <p className="muted">Увімкніть BeamDeck Agent і під’єднайте обидва пристрої до однієї Wi-Fi мережі.</p>
      {loading ? <div className="loading-line" role="status"><LoaderCircle size={18} /> Перевіряємо з’єднання…</div> : <>
        {canPair ? <form className="pair-form" onSubmit={submit}>
          <label htmlFor="pin">Шестизначний PIN з екрана Agent</label>
          <input id="pin" type="text" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6}
            value={pin} onChange={event => { setPin(event.target.value.replace(/\D/g, '').slice(0, 6)); setError('') }} required />
          <button className="primary" type="submit" disabled={pin.length !== 6 || pending}>
            {pending ? 'Підключаємо…' : 'Підключити пульт'} <ArrowRight size={17} />
          </button>
          {error && <p className="error" role="alert">{error}</p>}
        </form> : <div className="notice error"><WifiOff size={18} /><p>{detail}</p><button onClick={onRetry}>Повторити</button></div>}
        <div className="qr-note"><ScanLine size={19} /><span>Відскануйте QR-код на екрані Agent камерою iPhone або введіть адресу.</span></div>
        <AddressForm />
        <button className="text-button" onClick={onDemo}><Gamepad2 size={18} /> Відкрити деморежим</button>
      </>}
    </div>
  </main>
}

function AppIcon({ app }: { app: LaunchableApp }) {
  const label = app.label.toLocaleLowerCase()
  const kind = label.includes('youtube') ? 'video' : label.includes('vlc') ? 'film' :
    /браузер|browser|chrome|firefox|opera|edge/.test(label) ? 'web' : /файли|files/.test(label) ? 'files' : 'generic'
  const Icon = { video: TvMinimalPlay, film: Film, web: Compass, files: FolderClosed, generic: Grid2X2 }[kind]
  return <span className={'app-icon ' + kind}><Icon size={19} /></span>
}

function formatRemaining(ms: number) {
  const seconds = Math.ceil(ms / 1000)
  const minutes = Math.floor(seconds / 60)
  return String(minutes).padStart(2, '0') + ':' + String(seconds % 60).padStart(2, '0')
}

function DeviceCard({ status, connected, demo }: { status: Status; connected: boolean; demo: boolean }) {
  return <div className="device-card glass">
    <span className="device-icon"><Projector size={22} /></span>
    <div className="min-w-0"><strong>{status.device.model}</strong><span>{demo ? 'Демонстраційний проєктор' : status.device.manufacturer}</span></div>
    <span className={'device-led ' + (connected ? 'lit' : '')} aria-label={connected ? 'На зв’язку' : 'Поза мережею'} />
  </div>
}

type ControlProps = {
  status: Status
  disabled: boolean
  run: (action: Action) => Promise<boolean>
  blocked: (key: CapabilityKey) => boolean
}

function RemoteControl({ status, disabled, run, blocked, onKeyboard, sendSliderVolume, sliderDisabled }: ControlProps & {
  onKeyboard: () => void
  sendSliderVolume: (level: number) => Promise<void>
  sliderDisabled: boolean
}) {
  const [touch, setTouch] = useState(false)
  const [draft, setDraft] = useState<number | null>(null)
  const volumeTask = useRef<number | undefined>(undefined)
  const desiredVolume = useRef<number | null>(null)
  const sendingVolume = useRef(false)
  const lastVolumeSent = useRef(-Infinity)
  const volumeActive = useRef(true)
  const sendLatestVolume = useRef(sendSliderVolume)
  sendLatestVolume.current = sendSliderVolume
  const start = useRef<{ x: number; y: number } | null>(null)
  const effectiveVolume = { ...status.volume, current: draft ?? status.volume.current }
  const percent = volumePercent(effectiveVolume)
  const explainControls: CapabilityKey[] = ['back', 'home', 'ok', 'up', 'down', 'left', 'right',
    'playPause', 'previous', 'next', 'volume']
  const issues = Array.from(new Set(explainControls.map(key => unavailable(status.capabilities[key])).filter(Boolean)))
  const touchEnabled = directions.some(direction => status.capabilities[direction.command].available) || status.capabilities.ok.available

  useEffect(() => {
    volumeActive.current = true
    return () => {
      volumeActive.current = false
      desiredVolume.current = null
      window.clearTimeout(volumeTask.current)
      volumeTask.current = undefined
    }
  }, [])

  function send(command: Command) {
    if (!blocked(command)) void run({ type: 'command', command })
  }
  function sendPendingVolume() {
    if (!volumeActive.current || sendingVolume.current || desiredVolume.current === null) return
    const remaining = 180 - (performance.now() - lastVolumeSent.current)
    if (remaining > 0) {
      if (volumeTask.current === undefined) {
        volumeTask.current = window.setTimeout(() => {
          volumeTask.current = undefined
          sendPendingVolume()
        }, remaining)
      }
      return
    }
    const level = desiredVolume.current
    desiredVolume.current = null
    sendingVolume.current = true
    lastVolumeSent.current = performance.now()
    void sendLatestVolume.current(level).finally(() => {
      sendingVolume.current = false
      if (!volumeActive.current) return
      if (desiredVolume.current !== null) sendPendingVolume()
      else setDraft(null)
    })
  }

  function onVolume(level: number) {
    setDraft(level)
    desiredVolume.current = level
    sendPendingVolume()
  }
  function beginTouch(event: PointerEvent<HTMLButtonElement>) {
    if (event.button !== 0) return
    start.current = { x: event.clientX, y: event.clientY }
    event.currentTarget.setPointerCapture(event.pointerId)
  }
  function endTouch(event: PointerEvent<HTMLButtonElement>) {
    if (!start.current) return
    const x = event.clientX - start.current.x
    const y = event.clientY - start.current.y
    start.current = null
    if (Math.max(Math.abs(x), Math.abs(y)) < 20) send('ok')
    else send(Math.abs(x) > Math.abs(y) ? (x > 0 ? 'right' : 'left') : (y > 0 ? 'down' : 'up'))
  }

  return <section className="remote-shell glass" aria-label="Кнопки пульта">
    <div className="pad-header"><span><span className="mini-lens" />{status.projector?.navigation === 'lumina' ? 'Lumina Go' : 'Навігація'}</span>
      <div className="remote-modes"><button className="mode-toggle" title={touch ? 'Перейти до стрілок' : 'Перейти до сенсорної панелі'}
        aria-label="Сенсорна панель" aria-pressed={touch && touchEnabled} disabled={!touchEnabled}
        onClick={() => setTouch(value => !value)}><MousePointer2 size={15} /><span>{touch && touchEnabled ? 'Дотик' : 'Стрілки'}</span></button>
        <button className="mode-toggle keyboard-trigger" aria-label="Відкрити клавіатуру" title="Клавіатура" onClick={onKeyboard}><Keyboard size={18} /></button></div>
    </div>
    <div className="lens-wrap">
      <div className="lens-ring">
        {touch && touchEnabled ? <button className="touch-surface" disabled={disabled} onPointerDown={beginTouch} onPointerUp={endTouch}
          onPointerCancel={() => { start.current = null }} onClick={event => { if (event.detail === 0) send('ok') }}
          aria-label="Сенсорна панель. Свайп для навігації, дотик для OK">
          <MousePointer2 size={30} /><span>Свайп або дотик</span>
        </button> : <>
          {directions.map(({ command, label, icon: Icon }) =>
            <IconButton key={command} label={label} className={'direction ' + command} disabled={blocked(command)} onClick={() => send(command)}>
              <Icon size={21} />
            </IconButton>,
          )}
          <IconButton label="OK" className="ok" disabled={blocked('ok')} onClick={() => send('ok')}><span>OK</span></IconButton>
        </>}
      </div>
    </div>
    <div className="transport">
      <IconButton label="Назад" disabled={blocked('back')} onClick={() => send('back')}><Undo2 size={22} /></IconButton>
      <IconButton label="Попередній" disabled={blocked('previous')} onClick={() => send('previous')}><SkipBack size={20} /></IconButton>
      <IconButton label={status.media.playing ? 'Пауза' : 'Відтворити / пауза'} className="play-key" disabled={blocked('playPause')} onClick={() => send('playPause')}>
        {status.media.playing ? <Pause size={23} /> : <Play size={23} />}
      </IconButton>
      <IconButton label="Наступний" disabled={blocked('next')} onClick={() => send('next')}><SkipForward size={20} /></IconButton>
      <IconButton label="Додому" disabled={blocked('home')} onClick={() => send('home')}><House size={20} /></IconButton>
    </div>
    <div className="volume-block">
      <div className="volume-heading"><label htmlFor="remote-volume">Гучність</label><output htmlFor="remote-volume">{percent}%</output></div>
      <div className="volume-controls">
        <IconButton label="Тихіше" disabled={blocked('volumeDown')} onClick={() => send('volumeDown')}><Minus size={19} /></IconButton>
        <input className="range" id="remote-volume" type="range" min={status.volume.min} max={status.volume.max} step={1}
          value={effectiveVolume.current} disabled={sliderDisabled} onChange={event => onVolume(Number(event.target.value))}
          style={{ '--progress': percent + '%' } as React.CSSProperties} aria-valuetext={percent + ' відсотків'} />
        <IconButton label="Голосніше" disabled={blocked('volumeUp')} onClick={() => send('volumeUp')}><Plus size={19} /></IconButton>
        <IconButton label={status.volume.muted ? 'Увімкнути звук' : 'Вимкнути звук'} pressed={status.volume.muted}
          disabled={blocked('mute')} className="mute-key" onClick={() => send('mute')}>
          {status.volume.muted ? <VolumeX size={19} /> : <Volume2 size={19} />}
        </IconButton>
      </div>
    </div>
    {issues.length > 0 && <div className="remote-help">
      {issues.map(issue => <p key={issue}><CircleHelp size={15} />{issue}</p>)}
    </div>}
  </section>
}

function TimerCard({ status, run, blocked, disabled }: ControlProps) {
  const [time, setTime] = useState(30)
  const { sleep } = status
  const active = sleep.remainingMs !== null
  return <section className="glass feature-card">
    <div className="feature-title"><span className="feature-icon"><Moon size={21} /></span><div><h2>Таймер сну</h2><p>{sleepOutcomes[sleep.outcome]}</p></div></div>
    {active ? <div className="timer-active"><strong>{formatRemaining(sleep.remainingMs!)}</strong>
      <button className="secondary" disabled={disabled} onClick={() => void run({ type: 'sleep', minutes: 0 })}>Скасувати</button>
    </div> : <div className="feature-form">
      <label htmlFor="minutes">Тривалість</label>
      <select id="minutes" value={time} onChange={event => setTime(Number(event.target.value))}>
        {sleepOptions.map(minutes => <option key={minutes} value={minutes}>{minutes} хв</option>)}
      </select>
      <button className="primary" disabled={blocked('sleep')} onClick={() => void run({ type: 'sleep', minutes: time })}>
        <Clock3 size={18} /> Запустити таймер
      </button>
    </div>}
  </section>
}

function SceneCard({ apps, demo, run, blocked, status }: ControlProps & { apps: LaunchableApp[]; demo: boolean }) {
  const saveKey = demo ? 'demo.scene' : 'scene'
  const [settings, setSettings] = useState(() => read(saveKey, { appId: '', percent: 30 }))
  const chosen = apps.some(app => app.id === settings.appId) ? settings.appId : (apps.find(app => app.label === 'VLC') ?? apps[0])?.id ?? ''
  function update(value: typeof settings) {
    setSettings(value)
    save(saveKey, value)
  }
  return <section className="glass feature-card movie-card">
    <div className="feature-title"><span className="feature-icon"><Clapperboard size={21} /></span>
      <div><h2>Movie Night</h2><p>Встановлює гучність і відкриває вибраний плеєр.</p></div>
    </div>
    <div className="feature-form">
      <label htmlFor="movie-app">Плеєр</label>
      <select id="movie-app" value={chosen} onChange={event => update({ ...settings, appId: event.target.value })}>
        {!apps.length && <option value="">Доступних програм немає</option>}
        {apps.map(app => <option key={app.id} value={app.id}>{app.label}</option>)}
      </select>
      <div className="volume-heading"><label htmlFor="movie-volume">Гучність сцени</label><output>{settings.percent}%</output></div>
      <input type="range" className="range" id="movie-volume" min="0" max="100" value={settings.percent}
        style={{ '--progress': settings.percent + '%' } as React.CSSProperties}
        onChange={event => update({ ...settings, percent: Number(event.target.value) })} />
      <button className="primary" disabled={!chosen || blocked('launch') || blocked('volume')}
        onClick={() => void run({ type: 'scene', appId: chosen, percent: settings.percent })}><Play size={18} /> Запустити Movie Night</button>
      {(unavailable(status.capabilities.launch) || unavailable(status.capabilities.volume)) &&
        <p className="muted">{unavailable(status.capabilities.launch) || unavailable(status.capabilities.volume)}</p>}
    </div>
  </section>
}

export function App() {
  const [demo, setDemo] = useState(initialDemo)
  const [screen, setScreen] = useState<Screen>('remote')
  const [keyboard, setKeyboard] = useState(false)
  const [version, setVersion] = useState(0)
  const { agent, status, connection, detail, refresh, reportVolume } = useAgent(demo, version)
  const [apps, setApps] = useState<LaunchableApp[]>([])
  const [appProblem, setAppProblem] = useState('')
  const [loadingApps, setLoadingApps] = useState(false)
  const [busy, setBusy] = useState(false)
  const acting = useRef(false)
  const [feedback, setFeedback] = useState<{ text: string; error: boolean }>()
  const [haptics, setHaptics] = useState(() => read('haptics', true))
  const favoritesKey = demo ? 'demo.favorites' : 'favorites'
  const [favorites, setFavorites] = useState<string[]>(() => read(favoritesKey, []))
  const needsAgent = location.protocol !== 'file:'
  const connected = connection === 'connected'
  const selectedApps = apps.filter(app => favorites.includes(app.id))

  useEffect(() => {
    if (!connected) return
    let cancelled = false
    setLoadingApps(true)
    setAppProblem('')
    void agent.apps().then(next => { if (!cancelled) setApps(next) })
      .catch(error => { if (!cancelled) setAppProblem(explain(error)) })
      .finally(() => { if (!cancelled) setLoadingApps(false) })
    return () => { cancelled = true }
  }, [agent, connected, screen])

  useEffect(() => {
    if (!feedback) return
    const timer = window.setTimeout(() => setFeedback(undefined), feedback.error ? 6500 : 3600)
    return () => window.clearTimeout(timer)
  }, [feedback])

  function changeScreen(next: Screen) {
    setKeyboard(false)
    setScreen(next)
    window.scrollTo(0, 0)
  }

  function changeMode(value: boolean) {
    if (acting.current) return
    setDemo(value)
    setApps([])
    setFeedback(undefined)
    setFavorites(read(value ? 'demo.favorites' : 'favorites', []))
    changeScreen('remote')
    const url = new URL(location.href)
    if (value) url.searchParams.set('demo', '1')
    else url.searchParams.delete('demo')
    try { history.replaceState(null, '', url) } catch { /* file URL */ }
    setVersion(current => current + 1)
  }

  function toggleFavorite(app: LaunchableApp) {
    const next = favorites.includes(app.id) ? favorites.filter(id => id !== app.id) : [...favorites, app.id]
    setFavorites(next)
    save(favoritesKey, next)
  }

  async function run(action: Action) {
    if (acting.current || !connected) return false
    acting.current = true
    setBusy(true)
    setFeedback(undefined)
    try {
      if (haptics && typeof navigator.vibrate === 'function') navigator.vibrate(12)
      const result = await agent.act(action)
      if (result.volume) reportVolume(result.volume)
      else if (result.code !== 'lumina_submitted') await refresh.current()
      if (result.outcome === 'submitted' && action.type !== 'input' && result.code !== 'lumina_submitted') {
        const text = action.type === 'scene' ? 'Гучність встановлено. Запит на запуск надіслано Android.' :
          (action.type === 'launch' || action.type === 'open') ? 'Запит на відкриття надіслано Android.' : 'Команду передано плеєру.'
        setFeedback({ text, error: false })
      } else if (demo && action.type === 'command' && simulatedCommands[action.command]) {
        setFeedback({ text: 'Деморежим · ' + simulatedCommands[action.command], error: false })
      } else if (action.type === 'launch' || action.type === 'scene' || action.type === 'sleep') {
        const text = action.type === 'sleep' ? (action.minutes ? 'Таймер запущено.' : 'Таймер скасовано.') :
          action.type === 'scene' ? 'Сцену запущено в деморежимі.' : 'Програму відкрито в деморежимі.'
        setFeedback({ text, error: false })
      }
      return true
    } catch (error) {
      if (error instanceof AgentError && (error.status === 401 || error.status === 0 || error.code === 'partial_scene')) void refresh.current()
      setFeedback({ text: explain(error), error: true })
      return false
    } finally {
      acting.current = false
      setBusy(false)
    }
  }

  async function sendSliderVolume(level: number) {
    if (!connected) return
    try {
      const result = await agent.act({ type: 'volume', level })
      if (result.volume) reportVolume(result.volume)
      else await refresh.current()
    } catch (error) {
      setFeedback({ text: explain(error), error: true })
      void refresh.current()
    }
  }

  async function logout() {
    if (acting.current || !connected) return
    acting.current = true
    setBusy(true)
    try {
      await agent.logout()
      setApps([])
      changeScreen('remote')
      setVersion(current => current + 1)
    } catch (error) {
      setFeedback({ text: explain(error), error: true })
      void refresh.current()
    } finally {
      acting.current = false
      setBusy(false)
    }
  }

  const blocked = (key: CapabilityKey) => !connected || busy || status?.capabilities[key]?.available !== true
  const control = status ? { status, run, blocked, disabled: !connected || busy } : undefined
  const badge = demo ? 'Деморежим' : connected ? 'На зв’язку' : connection === 'loading' ? 'Підключення' :
    connection === 'pairing' ? 'Очікує на PIN' : 'Поза мережею'
  const BadgeIcon = demo ? Radio : connected ? Wifi : connection === 'loading' ? LoaderCircle : WifiOff

  return <div className="app">
    <header className="topbar">
      <div className="brand"><Mark /><span>BeamDeck</span></div>
      {status && <Nav screen={screen} onChange={changeScreen} />}
      <div className={'connection-badge ' + (demo ? 'demo' : connected ? 'online' : '')} role="status">
        <BadgeIcon size={15} /><span>{badge}</span>
      </div>
    </header>
    {!status || !control ? <Connect loading={connection === 'loading'} detail={connection === 'error' ? detail : ''}
      onDemo={() => changeMode(true)} onRetry={() => void refresh.current()}
      onPair={async pin => { await agent.pair(pin); setVersion(current => current + 1) }} />
      : <main className={screen === 'remote' ? 'remote-main' : 'section-main'}>
        {connection === 'disconnected' && <div className="notice offline"><WifiOff size={18} /><p>{detail} Повторюємо підключення.</p>
          <button onClick={() => void refresh.current()}>Повторити</button></div>}
        {screen === 'remote' && <div className="remote-grid">
          <section className="remote-intro">
            <h1>Пульт</h1>
            <DeviceCard status={status} connected={connected} demo={demo} />
            <div className="media-status"><span className="media-icon"><AudioLines size={18} /></span>
              <div><strong>{status.media.app ?? 'Медіа'}</strong>
                <span>{status.media.playing === true ? 'Відтворюється' : status.media.playing === false ? 'На паузі або зупинено' : 'Немає даних про відтворення'}</span></div>
            </div>
          </section>
          <RemoteControl {...control} sendSliderVolume={sendSliderVolume}
            sliderDisabled={!connected || status.capabilities.volume?.available !== true} onKeyboard={() => { setFeedback(undefined); setKeyboard(true) }} />
          <aside className="remote-aside">
            <div className="aside-head"><h2>Швидкий запуск</h2><button className="text-button" onClick={() => changeScreen('apps')}>Усі <ArrowUpRight size={16} /></button></div>
            <div className="app-shortcuts">
              {(selectedApps.length ? selectedApps : apps).slice(0, 3).map(app =>
                <button className="shortcut" key={app.id} disabled={blocked('launch')} onClick={() => void run({ type: 'launch', appId: app.id })}>
                  <AppIcon app={app} /><span>{app.label}</span>
                </button>,
              )}
              {!apps.length && <p className="muted">{appProblem || (loadingApps ? 'Завантажуємо програми…' : 'Доступних програм немає.')}</p>}
            </div>
            {unavailable(status.capabilities.launch) && <p className="hint">{unavailable(status.capabilities.launch)}</p>}
            <button className="aside-link glass" onClick={() => changeScreen('scenes')}>
              <span className="feature-icon"><Clapperboard size={18} /></span><span><strong>Movie Night</strong><small>Сцена для перегляду</small></span><ChevronRight size={17} />
            </button>
            <button className="aside-link glass" onClick={() => changeScreen('scenes')}>
              <span className="feature-icon moon"><Moon size={18} /></span><span><strong>Таймер сну</strong>
                <small>{status.sleep.remainingMs === null ? 'Налаштувати' : formatRemaining(status.sleep.remainingMs)}</small></span><ChevronRight size={17} />
            </button>
          </aside>
        </div>}
        {screen === 'geometry' && <GeometryStudio status={status} demo={demo} busy={busy} connected={connected} run={run} />}
        {screen === 'apps' && <>
          <div className="page-head"><h1>Програми</h1><p className="muted">{demo ? 'Програми демонстраційного проєктора.' : 'Програми, які Agent знайшов на проєкторі.'}</p></div>
          {appProblem && <p className="notice error" role="alert">{appProblem}</p>}
          {unavailable(status.capabilities.launch) && <p className="notice"><CircleHelp size={18} />{unavailable(status.capabilities.launch)}</p>}
          {loadingApps && !apps.length && <p className="loading-line" role="status"><LoaderCircle size={18} /> Завантажуємо програми…</p>}
          {!loadingApps && !apps.length && !appProblem && <p className="muted">Доступних програм немає.</p>}
          {[
            { label: 'Обрані', list: selectedApps },
            { label: selectedApps.length ? 'Інші програми' : 'Усі програми', list: apps.filter(app => !favorites.includes(app.id)) },
          ].filter(group => group.list.length).map(group => <section className="app-group" key={group.label}>
            <h2>{group.label}</h2>
            <div className="glass app-list">{group.list.map(app => <div className="app-row" key={app.id}>
              <button className="launch-row" disabled={blocked('launch')} onClick={() => void run({ type: 'launch', appId: app.id })}>
                <AppIcon app={app} /><span>{app.label}</span><ArrowUpRight size={16} />
              </button>
              <IconButton label={'Обране: ' + app.label} pressed={favorites.includes(app.id)} onClick={() => toggleFavorite(app)}><Star size={19} /></IconButton>
            </div>)}</div>
          </section>)}
        </>}
        {screen === 'scenes' && <><div className="page-head"><h1>Сцени</h1></div>
          <div className="feature-grid"><SceneCard {...control} key={favoritesKey} apps={apps} demo={demo} /><TimerCard {...control} /></div>
        </>}
        {screen === 'settings' && <><div className="page-head"><h1>Налаштування</h1></div>
          <div className="feature-grid">
            <section className="feature-card glass">
              <div className="feature-title"><span className="feature-icon"><Wifi size={21} /></span><div><h2>З’єднання</h2><p>{badge}</p></div></div>
              <dl className="details"><div><dt>Проєктор</dt><dd>{status.device.model}</dd></div>
                <div><dt>Android</dt><dd>{status.device.android} (API {status.device.api})</dd></div>
                {!demo && <div><dt>Адреса</dt><dd>{location.host}</dd></div>}</dl>
              <AddressForm />
              {!demo && <button className="secondary disconnect" disabled={!connected || busy} onClick={() => void logout()}>Завершити сеанс</button>}
            </section>
            <section className="feature-card glass">
              <div className="feature-title"><span className="feature-icon"><Settings2 size={21} /></span><div><h2>Пульт</h2><p>Налаштування цього браузера</p></div></div>
              <label className="toggle-line"><span>Вібровідгук</span><input type="checkbox" checked={haptics}
                onChange={event => { setHaptics(event.target.checked); save('haptics', event.target.checked) }} /></label>
              {typeof navigator.vibrate !== 'function' && <p className="hint">Цей браузер не підтримує вібровідгук вебсторінок.</p>}
              {needsAgent && <button className="secondary disconnect" disabled={busy} onClick={() => changeMode(!demo)}>
                {demo ? 'Перейти до підключення' : 'Відкрити деморежим'}
              </button>}
              {!demo && <p className="hint">На iPhone відкрийте меню Safari й виберіть «На початковий екран» та «Відкрити як вебпрограму».</p>}
            </section>
          </div>
        </>}
      </main>}
    {keyboard && status && <RemoteKeyboard projector={status.projector} demo={demo} disabled={!connected || busy} problem={feedback?.error ? feedback.text : undefined} run={run}
      close={() => setKeyboard(false)} />}
    {feedback && !(keyboard && feedback.error) && <div className={'toast ' + (feedback.error ? 'error' : '')} role={feedback.error ? 'alert' : 'status'}>
      <span>{feedback.text}</span><button aria-label="Закрити повідомлення" onClick={() => setFeedback(undefined)}><X size={17} /></button>
    </div>}
  </div>
}
