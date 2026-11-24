import type { Geometry } from './geometry'
import type { CinemaSettings, PlayerStatus, ProjectorStatus } from './cinema'
export const commands = [
  'volumeUp', 'volumeDown', 'mute', 'playPause', 'previous', 'next',
  'back', 'home', 'up', 'down', 'left', 'right', 'ok',
  'focusUp', 'focusDown', 'autoFocus',
] as const
export type Command = (typeof commands)[number]
export type CapabilityKey = Command | 'volume' | 'launch' | 'sleep'
export type Capability = { available: true } | {
  available: false
  reason: 'unsupported' | 'accessibility_required' | 'media_access_required' |
    'no_media' | 'media_action_unavailable' | 'fixed_volume' | 'launch_blocked'
}
export type Capabilities = Record<CapabilityKey, Capability>
export type Device = { model: string; manufacturer: string; android: string; api: number }
export type LaunchableApp = { id: string; label: string }
export type Volume = { current: number; min: number; max: number; muted: boolean }
export type Sleep = {
  remainingMs: number | null
  outcome: 'idle' | 'scheduled' | 'submitted' | 'completed' | 'partial' | 'failed'
}
export type Status = {
  device: Device
  volume: Volume
  capabilities: Capabilities
  media: { playing: boolean | null; app: string | null }
  geometry?: Geometry
  cinema?: CinemaSettings
  projector?: ProjectorStatus
  player?: PlayerStatus
  sleep: Sleep
}
export type Outcome = { outcome: 'applied' | 'submitted'; code: string; volume?: Volume }
export type Action =
  | { type: 'command'; command: Command }
  | { type: 'volume'; level: number }
  | { type: 'launch'; appId: string }
  | { type: 'scene'; appId: string; percent: number }
  | { type: 'sleep'; minutes: number }
  | { type: 'input'; action: 'text' | 'delete' | 'enter'; text: string }
  | { type: 'open'; destination: 'grid' | 'player' | 'settings' | 'url'; value: string }
  | { type: 'geometry'; value: Geometry }
  | { type: 'cinema'; settings: CinemaSettings }
  | { type: 'playback' }
export type Connection = 'loading' | 'connected' | 'disconnected' | 'pairing' | 'error'
export type Screen = 'remote' | 'geometry' | 'apps' | 'scenes' | 'settings'

export function volumePercent(volume: Volume): number {
  return volume.max > volume.min
    ? Math.round((volume.current - volume.min) * 100 / (volume.max - volume.min))
    : 0
}

export const capabilityText: Record<Extract<Capability, { available: false }>['reason'], string> = {
  unsupported: 'Прошивка або ця версія Android не підтримує цю дію.',
  accessibility_required: 'Увімкніть службу спеціальних можливостей BeamDeck на проєкторі.',
  media_access_required: 'Надайте BeamDeck доступ до сповіщень на проєкторі для пошуку медіасесій.',
  no_media: 'Відкрийте плеєр і запустіть відтворення, щоб з’явилася медіасесія.',
  media_action_unavailable: 'Поточний плеєр не надає цю команду.',
  fixed_volume: 'Android повідомив, що рівень гучності фіксований.',
  launch_blocked: 'Відкрийте Agent або ввімкніть спеціальні можливості BeamDeck для запуску програм у фоні.',
}

export function unavailable(capability?: Capability) {
  return capability?.available === false ? capabilityText[capability.reason] : ''
}
