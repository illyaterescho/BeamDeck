import { identityGeometry } from './geometry'
import { baseCinema } from './cinema'
import { capabilityText, commands } from './model'
import type { Action, Capabilities, LaunchableApp, Outcome, Status } from './model'

export class AgentError extends Error {
  constructor(public code: string, public status: number) {
    super(code)
  }
}

const errorText: Record<string, string> = {
  bad_pin: 'PIN не збігається. Введіть код з екрана Agent.',
  pin_expired: 'Термін дії PIN сплив. Згенеруйте новий код на проєкторі.',
  rate_limited: 'Забагато запитів. Трохи зачекайте й спробуйте ще раз.',
  unauthorized: 'Сеанс завершився. Підключіться за PIN.',
  unreachable: 'Agent не відповідає. Перевірте Wi-Fi і стан сервера.',
  invalid_response: 'За цією адресою BeamDeck Agent не відповів очікуваним форматом.',
  not_found: 'Застосунок більше недоступний на проєкторі.',
  rejected: 'Android відхилив команду.',
  partial_scene: 'Гучність змінилася, але запустити плеєр не вдалося.',
  adb_lost: 'Системні кнопки тимчасово недоступні. Спробуйте ще раз.',
  adb_timeout: 'Проєктор не відповів вчасно. Спробуйте ще раз.',
  busy: 'Agent зайнятий. Спробуйте ще раз.',
  bad_request: 'Agent відхилив параметри запиту.',
  forbidden: 'Відкрийте пульт за адресою, яку показує Agent.',
  invalid_geometry: 'Збережіть опуклий чотирикутник у межах кадру.',
  keyboard_required: 'Увімкніть і виберіть клавіатуру BeamDeck на проєкторі.',
  field_required: 'Відкрийте текстове поле на проєкторі.',
  protected_field: 'Це захищене поле Android.',
  invalid_url: 'Введіть повне посилання, яке починається з https:// або http://.',
  video_required: 'Відкрийте відеофайл у плеєрі BeamDeck.',
  internal_error: 'Agent не зміг виконати запит.',
}

export function explain(error: unknown) {
  if (!(error instanceof AgentError)) return errorText.unreachable
  return errorText[error.code] ?? capabilityText[error.code as keyof typeof capabilityText] ?? errorText.internal_error
}

interface Agent {
  status(signal?: AbortSignal): Promise<Status>
  apps(): Promise<LaunchableApp[]>
  pair(pin: string): Promise<void>
  logout(): Promise<void>
  act(action: Action): Promise<Outcome>
}

async function request<T>(path: string, body?: object, signal?: AbortSignal): Promise<T> {
  const timeout = new AbortController()
  const timer = window.setTimeout(() => timeout.abort(), 6500)
  const abort = () => timeout.abort()
  signal?.addEventListener('abort', abort, { once: true })
  if (signal?.aborted) abort()
  try {
    const response = await fetch('/api/v1/' + path, {
      signal: timeout.signal,
      credentials: 'same-origin',
      cache: 'no-store',
      method: body ? 'POST' : 'GET',
      headers: body ? { 'Content-Type': 'application/json', 'X-BeamDeck-Request': '1' } : {},
      body: body ? JSON.stringify(body) : undefined,
    })
    if (!response.headers.get('content-type')?.includes('application/json')) {
      throw new AgentError('invalid_response', response.status)
    }
    const value = await response.json()
    if (!response.ok) throw new AgentError(value?.error?.code ?? 'internal_error', response.status)
    return value as T
  } catch (error) {
    if (error instanceof AgentError) throw error
    throw new AgentError('unreachable', 0)
  } finally {
    window.clearTimeout(timer)
    signal?.removeEventListener('abort', abort)
  }
}

export const realAgent: Agent = {
  status: signal => request('status', undefined, signal),
  apps: async () => (await request<{ apps: LaunchableApp[] }>('apps')).apps,
  pair: async pin => { await request('pair', { pin }) },
  logout: async () => { await request('logout', {}) },
  act: action => {
    switch (action.type) {
      case 'command': return request('command', { command: action.command })
      case 'volume': return request('volume', { level: action.level })
      case 'launch': return request('launch', { appId: action.appId })
      case 'scene': return request('scene', { appId: action.appId, percent: action.percent })
      case 'sleep': return request('sleep', { minutes: action.minutes })
      case 'input': return request('input', { action: action.action, text: action.text })
      case 'open': return request('cinema/open', { destination: action.destination, value: action.value })
      case 'geometry': return request('geometry', action.value)
      case 'cinema': return request('cinema/settings', { settings: action.settings })
      case 'playback': return request('cinema/playback', {})
    }
  },
}

const demoApps = [
  { id: 'demo-youtube', label: 'YouTube' },
  { id: 'demo-vlc', label: 'VLC' },
  { id: 'demo-browser', label: 'Браузер' },
  { id: 'demo-files', label: 'Файли' },
]
const demoCapabilities = Object.fromEntries(
  [...commands, 'volume', 'launch', 'sleep'].map(key => [key, { available: true }]),
) as Capabilities

export function createDemoAgent(): Agent {
  const state: Status = {
    device: { model: 'HY350 MAX', manufacturer: 'Magcubic', android: '13', api: 33 },
    volume: { current: 36, min: 0, max: 100, muted: false },
    capabilities: demoCapabilities,
    media: { playing: false, app: 'VLC' },
    sleep: { remainingMs: null, outcome: 'idle' },
    geometry: identityGeometry,
    cinema: baseCinema,
    projector: { focus: 'unsupported', keystone: 'player_only', hardwareAutoKeystone: 'unsupported',
      vendorLauncher: null, canOpen: true, keyboard: 'ready', display: 'closed', playing: false },
    player: { ready: false, effects: false, audio: false, fps: 0, reduced: false },
  }
  let deadline: number | null = null
  return {
    status: async () => {
      if (deadline !== null) {
        state.sleep.remainingMs = Math.max(0, deadline - Date.now())
        if (state.sleep.remainingMs === 0) {
          deadline = null
          state.volume.muted = true
          state.media.playing = false
          state.sleep = { remainingMs: null, outcome: 'completed' }
        }
      }
      return JSON.parse(JSON.stringify(state)) as Status
    },
    apps: async () => demoApps,
    pair: async () => {},
    logout: async () => {},
    act: async action => {
      const { volume, media } = state
      if (action.type === 'volume') {
        volume.current = action.level
        if (action.level > 0) volume.muted = false
      }
      if (action.type === 'command') {
        switch (action.command) {
          case 'volumeUp': volume.current = Math.min(100, volume.current + 5); volume.muted = false; break
          case 'volumeDown': volume.current = Math.max(0, volume.current - 5); break
          case 'mute': volume.muted = !volume.muted; break
          case 'playPause': media.playing = !media.playing; break
          case 'home': media.app = null; media.playing = false; break
        }
      }
      if (action.type === 'launch' || action.type === 'scene') {
        const app = demoApps.find(item => item.id === action.appId)
        if (!app) throw new AgentError('not_found', 404)
        media.app = app.label
        media.playing = false
        if (action.type === 'scene') {
          volume.current = action.percent
          volume.muted = false
        }
      }
      if (action.type === 'sleep') {
        deadline = action.minutes ? Date.now() + action.minutes * 60_000 : null
        state.sleep = { remainingMs: null, outcome: deadline ? 'scheduled' : 'idle' }
      }
      if (action.type === 'geometry') state.geometry = action.value
      if (action.type === 'cinema') state.cinema = action.settings
      const projector = state.projector!
      if (action.type === 'open' && (action.destination === 'grid' || action.destination === 'player')) {
        projector.display = action.destination
        projector.playing = action.destination === 'player'
        state.player = { ready: projector.playing, effects: projector.playing, audio: projector.playing, compression: projector.playing,
          fps: projector.playing ? 24 : 0, reduced: false }
      }
      if (action.type === 'playback') projector.playing = !projector.playing
      return { outcome: 'applied', code: 'demo' }
    },
  }
}

export function agentAddress(value: string): URL | null {
  const match = value.trim().match(/^(?:http:\/\/)?(\d{1,3}(?:\.\d{1,3}){3})(?::(\d{1,5}))?\/?$/)
  if (!match) return null
  const octets = match[1].split('.').map(Number)
  if (octets.some(n => n > 255)) return null
  const [a, b] = octets
  const local = a === 10 || (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) || (a === 169 && b === 254)
  const port = Number(match[2] ?? '8765')
  return local && port >= 1 && port <= 65535 ? new URL('http://' + octets.join('.') + ':' + port) : null
}

export const initialDemo = location.protocol === 'file:' || new URLSearchParams(location.search).get('demo') === '1'
