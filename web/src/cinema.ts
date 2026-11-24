export type CinemaSettings = {
  preset: 'natural' | 'cinema' | 'vivid' | 'custom'
  enabled: boolean
  contrast: number
  saturation: number
  warmth: number
  shadow: number
  gamma: number
  smoothing: number
  split: number
  dialogue: number
  captions: boolean
  captionSize: number
  captionPosition: number
  captionColor: 'white' | 'ivory' | 'yellow'
  captionBackground: boolean
  captionDelay: number
  lowPower: boolean
  adaptive: boolean
  compression: number
}
export type PlayerStatus = { ready: boolean; effects: boolean; audio: boolean; fps: number; reduced: boolean; compression?: boolean; sceneBrightness?: number | null }
export type ProjectorStatus = {
  focus: 'unsupported' | 'lumina'; navigation?: 'lumina'; keystone: 'player_only'; hardwareAutoKeystone: 'unsupported'
  vendorLauncher: string | null
  canOpen: boolean; keyboard: 'ready' | 'keyboard_required' | 'field_required' | 'protected_field'
  display: 'closed' | 'grid' | 'player'; playing: boolean
}

export const baseCinema: CinemaSettings = {
  preset: 'natural', enabled: false, contrast: 0, saturation: 0, warmth: 0, shadow: 0, gamma: 0,
  smoothing: 0, split: 100, dialogue: 0, captions: true, captionSize: 25, captionPosition: 8,
  captionColor: 'white', captionBackground: true, captionDelay: 0, lowPower: false, adaptive: false, compression: 0,
}
export const grades = [
  { title: 'Natural', preset: 'natural', contrast: 0, saturation: 0, warmth: 0, shadow: 0, gamma: 0 },
  { title: 'Cinema', preset: 'cinema', contrast: 9, saturation: -12, warmth: 16, shadow: 32, gamma: 6 },
  { title: 'Vivid', preset: 'vivid', contrast: 13, saturation: 26, warmth: -4, shadow: 13, gamma: 0 },
] as const
