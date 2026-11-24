import { useEffect, useRef, useState } from 'react'
import type { KeyboardEvent, PointerEvent } from 'react'
import {
  ArrowDown, ArrowLeft, ArrowRight, ArrowUp, Camera, Check, CircleHelp, Crosshair, Frame, Grid3X3,
  Maximize2, Minus, Play, Plus, RotateCcw, Scan, Undo2,
} from 'lucide-react'
import { analyseCalibration, photoPixels } from './calibration'
import type { Calibration } from './calibration'
import { baseCinema } from './cinema'
import type { CinemaSettings } from './cinema'
import { homography, identityGeometry, moveCorner, project, zoomOrMove } from './geometry'
import type { Geometry, Point, Quad } from './geometry'
import { useGeometryLink } from './GeometryLink'
import { CinemaPanel, ProfilesPanel } from './CinemaPanel'
import type { Action, Status } from './model'

type Tab = 'frame' | 'wall' | 'player' | 'profiles'
const names = ['Верхній лівий кут', 'Верхній правий кут', 'Нижній правий кут', 'Нижній лівий кут']
const regionNames = ['Верх ліворуч', 'Верх праворуч', 'Низ праворуч', 'Низ ліворуч', 'Центр']
const tabLabels = [
  ['frame', 'Геометрія'], ['wall', 'Калібрування'], ['player', 'Плеєр'], ['profiles', 'Профілі'],
] as const

function Drawing({ quad, reference = false }: { quad: Quad; reference?: boolean }) {
  const transform = homography(quad)
  const view = ([x, y]: Point) => [x * 1000, y * 600]
  const segments = Array.from({ length: 7 }, (_, i): [Point, Point][] => {
    const n = (i + 1) / 8
    return [[project(transform, [n, 0]), project(transform, [n, 1])],
      [project(transform, [0, n]), project(transform, [1, n])]]
  }).flat()
  return <svg className="geo-drawing" viewBox="0 0 1000 600" preserveAspectRatio="none" aria-hidden="true">
    {reference && <rect x="1" y="1" width="998" height="598" className="geo-reference" vectorEffect="non-scaling-stroke" />}
    <polygon points={quad.map(point => view(point).join(',')).join(' ')} className="geo-polygon" vectorEffect="non-scaling-stroke" />
    {segments.map(([a, b], index) => <line key={index} className={index === 6 || index === 7 ? 'geo-axis' : 'geo-line'}
      x1={view(a)[0]} y1={view(a)[1]} x2={view(b)[0]} y2={view(b)[1]} vectorEffect="non-scaling-stroke" />)}
  </svg>
}

function FrameEditor({ value, onUpdate, onFinish, onUndo, onReset, canUndo }: {
  value: Geometry; onUpdate: (value: Geometry) => void; onFinish: (before: Geometry, next: Geometry) => void
  onUndo: () => void; onReset: () => void; canUndo: boolean
}) {
  const live = useRef(value)
  live.current = value
  const field = useRef<HTMLDivElement>(null)
  const pointers = useRef(new Map<number, { index: number; dx: number; dy: number }>())
  const start = useRef<Geometry | null>(null)
  const [active, setActive] = useState<number[]>([])

  function update(next: Geometry) {
    live.current = next
    onUpdate(next)
  }

  function position(event: PointerEvent<HTMLButtonElement>): Point {
    const rect = field.current!.getBoundingClientRect()
    return [(event.clientX - rect.left) / rect.width, (event.clientY - rect.top) / rect.height]
  }

  function down(index: number, event: PointerEvent<HTMLButtonElement>) {
    if (event.button !== 0 || Array.from(pointers.current.values()).some(pointer => pointer.index === index)) return
    const [x, y] = position(event)
    const [oldX, oldY] = live.current.corners[index]
    if (!pointers.current.size) start.current = live.current
    pointers.current.set(event.pointerId, { index, dx: oldX - x, dy: oldY - y })
    event.currentTarget.setPointerCapture(event.pointerId)
    setActive(Array.from(pointers.current.values(), pointer => pointer.index))
  }

  function move(event: PointerEvent<HTMLButtonElement>) {
    const pointer = pointers.current.get(event.pointerId)
    if (!pointer) return
    const [x, y] = position(event)
    const corners = moveCorner(live.current.corners, pointer.index, [x + pointer.dx, y + pointer.dy])
    if (corners !== live.current.corners) update({ corners, mode: 'manual' })
  }

  function finish(event: PointerEvent<HTMLButtonElement>) {
    if (!pointers.current.delete(event.pointerId)) return
    setActive(Array.from(pointers.current.values(), pointer => pointer.index))
    if (!pointers.current.size && start.current) {
      if (start.current !== live.current) onFinish(start.current, live.current)
      start.current = null
    }
  }

  function key(index: number, event: KeyboardEvent<HTMLButtonElement>) {
    const vectors: Record<string, Point> = { ArrowLeft: [-1,0], ArrowRight: [1,0], ArrowUp: [0,-1], ArrowDown: [0,1] }
    const direction = vectors[event.key]
    if (!direction) return
    event.preventDefault()
    const before = live.current
    const [x, y] = before.corners[index]
    const step = event.shiftKey ? .04 : .008
    const corners = moveCorner(before.corners, index, [x + direction[0] * step, y + direction[1] * step])
    if (corners !== before.corners) onFinish(before, { corners, mode: 'manual' })
  }

  return <section className="perspective" aria-label="Редактор чотирьох кутів">
    <div className="perspective-bar"><span><Frame size={17} /> Проєкція</span>
      <div><button className="studio-icon" aria-label="Скасувати зміну" title="Скасувати зміну" disabled={!canUndo || active.length > 0} onClick={onUndo}><Undo2 size={19} /></button>
        <button className="studio-icon" aria-label="Скинути геометрію" title="Скинути геометрію" disabled={active.length > 0} onClick={onReset}><RotateCcw size={18} /></button>
      </div>
    </div>
    <div className="geo-stage">
      <div className="geo-field" ref={field}>
        <Drawing quad={value.corners} reference />
        {value.corners.map(([x, y], index) => <button key={index} type="button" aria-label={names[index]}
          className={'corner-handle' + (active.includes(index) ? ' grabbing' : '')}
          style={{ left: x * 100 + '%', top: y * 100 + '%' }}
          onPointerDown={event => down(index, event)} onPointerMove={move}
          onPointerUp={event => { move(event); finish(event) }} onPointerCancel={finish} onLostPointerCapture={finish}
          onKeyDown={event => key(index, event)}><span /></button>)}
      </div>
    </div>
    <div className="perspective-caption">Перетягніть кути. На клавіатурі скористайтеся стрілками.</div>
  </section>
}

export function GeometryStudio({ status, demo, connected, busy, run }: {
  status: Status; demo: boolean; connected: boolean; busy: boolean; run: (action: Action) => Promise<boolean>
}) {
  const [tab, setTab] = useState<Tab>('frame')
  const [value, setValue] = useState(() => status.geometry ?? identityGeometry)
  const [settings, setSettings] = useState(() => status.cinema ?? baseCinema)
  const [history, setHistory] = useState<Geometry[]>([])
  const [calibration, setCalibration] = useState<Calibration>()
  const [problem, setProblem] = useState('')
  const [scanning, setScanning] = useState(false)
  const [guide, setGuide] = useState(false)
  const canOpen = connected && !busy && (demo || status.projector?.canOpen === true)
  const link = useGeometryLink(connected && Boolean(status.geometry), demo,
    next => run({ type: 'geometry', value: next }))
  const saveLabels = { local: 'Локальний перегляд', connecting: 'З’єднуємо сітку', ready: 'Готово до калібрування',
    saving: 'Збереження…', saved: demo ? 'Збережено в демо' : 'Agent підтвердив геометрію', error: 'Agent не підтвердив зміни' }
  const readyGrid = status.projector?.display === 'grid'

  function change(before: Geometry, next: Geometry) {
    setHistory(previous => [...previous.slice(-24), before])
    setValue(next)
    void link.save(next)
  }

  function modify(scale: number, x = 0, y = 0) {
    const corners = zoomOrMove(value.corners, scale, x, y)
    if (corners !== value.corners) change(value, { corners, mode: 'manual' })
  }

  function undo() {
    const previous = history.at(-1)
    if (!previous) return
    setHistory(history.slice(0, -1))
    setValue(previous)
    void link.save(previous)
  }

  async function analyse(file: File | undefined) {
    if (!file) return
    setProblem('')
    setCalibration(undefined)
    setScanning(true)
    try { setCalibration(analyseCalibration(await photoPixels(file), status.geometry?.corners ?? value.corners)) }
    catch (error) { setProblem(error instanceof Error ? error.message : 'Не вдалося обробити фото.') }
    finally { setScanning(false) }
  }

  async function applyProfile(next: Geometry, cinema: CinemaSettings) {
    if (!(await link.save(next, true))) return false
    setHistory(previous => [...previous.slice(-24), value])
    setValue(next)
    if (!(await run({ type: 'cinema', settings: cinema }))) return false
    setSettings(cinema)
    return true
  }

  function open(destination: 'grid' | 'player' | 'settings') {
    void run({ type: 'open', destination, value: '' })
  }

  return <div className="studio">
    <div className="studio-head"><div><h1>Екран</h1>
      <p>{demo ? 'Калібрування й плеєр · демо' : 'Калібрування та плеєр BeamDeck'}</p></div>
      <button className="secondary" disabled={!canOpen} onClick={() => open('grid')}><Maximize2 size={18} /> Сітка</button>
    </div>
    {connected && !demo && status.projector?.canOpen === false && <p className="hint">
      На проєкторі відкрийте BeamDeck Agent → «Тестова сітка на проєкторі». Для відкриття з телефона, коли Agent у фоні, увімкніть «BeamDeck · Навігація» в Android.
    </p>}
    <nav className="studio-tabs" aria-label="Екран і калібрування">
      {tabLabels.map(([id, label]) => <button type="button" key={id} aria-current={id === tab ? 'page' : undefined}
        onClick={() => setTab(id)}>{label}</button>)}
    </nav>
    {tab === 'frame' && <div className="studio-layout">
      <FrameEditor value={value} canUndo={history.length > 0} onUndo={undo} onReset={() => change(value, identityGeometry)}
        onUpdate={next => { setValue(next); link.preview(next) }} onFinish={change} />
      <aside className="studio-side">
        <p className="studio-status" role="status"><span className={link.state === 'error' ? 'warn' : ''} />{saveLabels[link.state]}</p>
        {link.state === 'error' && <button className="secondary" disabled={!connected || busy} onClick={() => void link.save(value, true)}>Повторити збереження</button>}
        <section className="studio-section">
          <h2>Корекція трапеції</h2>
          <div className="studio-pair"><button type="button" aria-pressed={value.mode === 'manual'} onClick={() => {
            if (value.mode !== 'manual') change(value, { ...value, mode: 'manual' })
          }}>Вручну</button><button type="button" aria-pressed={value.mode === 'auto'} onClick={() => setTab('wall')}>Auto Keystone з фото</button></div>
          <p className="hint">Геометрія застосовується до сітки й відео в BeamDeck. Системна трапеція залежить від прошивки.</p>
        </section>
        <section className="studio-section compact-tools">
          <div><h2>Масштаб</h2><div className="tools">
            <button className="studio-icon" aria-label="Зменшити проєкцію" onClick={() => modify(.94)}><Minus size={19} /></button>
            <button className="studio-icon" aria-label="Збільшити проєкцію" onClick={() => modify(1.065)}><Plus size={19} /></button>
          </div></div>
          <div><h2>Позиція</h2><div className="tools">
            <button className="studio-icon" aria-label="Зсунути ліворуч" onClick={() => modify(1, -.02)}><ArrowLeft size={18} /></button>
            <button className="studio-icon" aria-label="Зсунути вгору" onClick={() => modify(1, 0, -.02)}><ArrowUp size={18} /></button>
            <button className="studio-icon" aria-label="Зсунути вниз" onClick={() => modify(1, 0, .02)}><ArrowDown size={18} /></button>
            <button className="studio-icon" aria-label="Зсунути праворуч" onClick={() => modify(1, .02)}><ArrowRight size={18} /></button>
          </div></div>
        </section>
        <section className="studio-section">
          <h2>Фокус об’єктива</h2>
          {(status.capabilities.focusUp?.available || status.capabilities.focusDown?.available) ? <div className="tools">
          <button className="studio-icon" aria-label="Фокус мінус" disabled={!connected || busy || !status.capabilities.focusDown?.available}
            onClick={() => void run({ type: 'command', command: 'focusDown' })}><Minus size={19} /></button>
          <button className="studio-icon" aria-label="Фокус плюс" disabled={!connected || busy || !status.capabilities.focusUp?.available}
            onClick={() => void run({ type: 'command', command: 'focusUp' })}><Plus size={19} /></button>
          <button className="secondary" disabled={!connected || busy || !status.capabilities.autoFocus?.available}
            onClick={() => void run({ type: 'command', command: 'autoFocus' })}>Автофокус</button>
        </div> : <p className="hint">Навчіть кнопки фокуса в програмі BeamDeck для iPhone (Проєктор → Кнопки пульта) і ввімкніть налагодження по мережі на проєкторі.</p>}
          <button className="secondary" disabled={!canOpen} onClick={() => open('settings')}><Crosshair size={17} /> Налаштування проєктора</button>
          <button className="text-button" onClick={() => setTab('wall')}>Перевірити різкість за фото</button>
        </section>
      </aside>
    </div>}
    {tab === 'wall' && <div className="calibration-layout">
      <section className="studio-section calibration-steps">
        <h2>Фото тестової сітки</h2>
        <p>Покажіть сітку на проєкторі. Тримайте iPhone паралельно стіні й залиште в кадрі всі чотири кольорові мітки.</p>
        <button className="secondary" disabled={!canOpen} onClick={() => open('grid')}><Grid3X3 size={18} /> {readyGrid ? 'Сітка відкрита' : 'Показати сітку'}</button>
        <label className="primary file-button"><Camera size={18} />
          {scanning ? 'Читаємо мітки…' : 'Зняти або вибрати фото'}
          <input type="file" accept="image/*" capture="environment" disabled={scanning}
            onChange={event => { void analyse(event.target.files?.[0]); event.currentTarget.value = '' }} />
        </label>
        {problem && <p className="error" role="alert">{problem}</p>}
        <button className="text-button" onClick={() => setGuide(!guide)}><CircleHelp size={17} /> Точність вимірювання</button>
        {guide && <p className="hint">Обробка фото відбувається в браузері. Кут камери й автоекспозиція впливають на оцінку. Для порівняння фокуса знімайте з тієї самої точки.</p>}
      </section>
      {calibration ? <section className="studio-section calibration-result">
        <h2>Рекомендована корекція</h2>
        <div className="compare-grids"><figure><Drawing quad={calibration.observed} /><figcaption>Зі знімка</figcaption></figure>
          <figure><Drawing quad={calibration.suggested} /><figcaption>Профіль BeamDeck</figcaption></figure></div>
        <button className="primary" onClick={() => { change(value, { corners: calibration.suggested, mode: 'auto' }); setTab('frame') }}><Check size={17} /> Застосувати корекцію</button>
        <h2>Різкість по зонах</h2>
        <div className="focus-map">{calibration.sharpness.map((value, index) => <div key={index}
          style={{ '--sharpness': (value / 100) + '' } as React.CSSProperties}><span>{regionNames[index]}</span><strong>{value}%</strong></div>)}</div>
        <p className="hint">Зони порівнюються з найрізкішою ділянкою цього фото. {calibration.exposure}. Відтінок білого на фото {calibration.whiteCast}. Розкид яскравості за знімком — {calibration.evenness}%.</p>
        <p className="hint">Якщо центр м’якший за кути, перевірте фокус. Якщо один бік помітно м’якший, звірте положення проєктора відносно стіни.</p>
      </section> : <div className="calibration-empty"><Scan size={36} /><p>Після фото тут з’являться геометрія та різкість по зонах.</p></div>}
    </div>}
    {tab === 'player' && <CinemaPanel status={status} draft={settings} setDraft={setSettings} connected={connected}
      busy={busy} run={run} canOpen={canOpen} />}
    {tab === 'profiles' && <ProfilesPanel geometry={value} cinema={settings} applyProfile={applyProfile} connected={connected}
      busy={busy} canOpen={canOpen} status={status} run={run} />}
  </div>
}
