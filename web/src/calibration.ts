import { homography, inverse, project, validQuad } from './geometry'
import type { Point, Quad } from './geometry'

export type Calibration = { observed: Quad; suggested: Quad; sharpness: number[]; exposure: string; whiteCast: string; evenness: number }

export async function photoPixels(file: File): Promise<ImageData> {
  if (file.size > 24_000_000) throw new Error('Виберіть фото розміром до 24 МБ.')
  const url = URL.createObjectURL(file)
  try {
    const image = new Image()
    image.src = url
    await image.decode()
    const factor = Math.min(1, 800 / Math.max(image.naturalWidth, image.naturalHeight))
    const canvas = document.createElement('canvas')
    canvas.width = Math.max(1, Math.round(image.naturalWidth * factor))
    canvas.height = Math.max(1, Math.round(image.naturalHeight * factor))
    const ctx = canvas.getContext('2d', { willReadFrequently: true })
    if (!ctx) throw new Error('Браузер не зміг прочитати пікселі.')
    ctx.drawImage(image, 0, 0, canvas.width, canvas.height)
    return ctx.getImageData(0, 0, canvas.width, canvas.height)
  } finally {
    URL.revokeObjectURL(url)
  }
}

export function analyseCalibration({ data, width, height }: ImageData, current: Quad): Calibration {
  const total = width * height
  const mask = new Uint8Array(total)
  for (let i = 0; i < total; i++) {
    const [r, g, b] = [data[i * 4], data[i * 4 + 1], data[i * 4 + 2]]
    if (g > 75 && b > 75 && Math.min(g, b) - r > 38 && Math.min(g, b) > Math.max(g, b) * .59) mask[i] = 1
    else if (r > 75 && b > 65 && Math.min(r, b) - g > 35) mask[i] = 2
    else if (r > 80 && g > 75 && Math.min(r, g) - b > 42 && Math.min(r, g) > Math.max(r, g) * .59) mask[i] = 3
    else if (g > 75 && g - Math.max(r, b) > 65) mask[i] = 4
  }

  const best = Array.from({ length: 4 }, () => ({ size: 0, x: 0, y: 0 }))
  const queue = new Int32Array(total)
  for (let start = 0; start < total; start++) {
    const kind = mask[start]
    if (!kind) continue
    let size = 1, index = 0, sumX = 0, sumY = 0
    mask[start] = 0
    queue[0] = start
    while (index < size) {
      const pixel = queue[index++], x = pixel % width, y = Math.floor(pixel / width)
      sumX += x; sumY += y
      if (x > 0 && mask[pixel - 1] === kind) { mask[pixel - 1] = 0; queue[size++] = pixel - 1 }
      if (x + 1 < width && mask[pixel + 1] === kind) { mask[pixel + 1] = 0; queue[size++] = pixel + 1 }
      if (y > 0 && mask[pixel - width] === kind) { mask[pixel - width] = 0; queue[size++] = pixel - width }
      if (y + 1 < height && mask[pixel + width] === kind) { mask[pixel + width] = 0; queue[size++] = pixel + width }
    }
    if (size > best[kind - 1].size) best[kind - 1] = { size, x: sumX / size / width, y: sumY / size / height }
  }
  const markers = best.map(point => [point.x, point.y]) as unknown as Quad
  if (!validQuad(markers) || best.some(point => point.size < Math.max(10, total * .000045))) {
    throw new Error('Не вдалося знайти всі чотири мітки. Сфотографуйте всю сітку рівно, з меншим навколишнім світлом.')
  }

  const pattern = homography(markers)
  const at = ([x, y]: Point) => project(pattern, [(x - .065) / .87, (y - .065) / .87])
  const observed = ([[0,0], [1,0], [1,1], [0,1]] as const).map(at) as unknown as Quad
  if (!validQuad(observed)) throw new Error('Краї сітки виходять за кадр. Залиште більше простору навколо проєкції.')
  const transform = inverse(homography(observed))
  const currentWarp = homography(current)
  const center = observed.reduce(([cx, cy], [x, y]) => [cx + x / 4, cy + y / 4] as Point, [0, 0] as Point)
  const spanX = (Math.max(...observed.map(p => p[0])) - Math.min(...observed.map(p => p[0]))) / 2
  const spanY = (Math.max(...observed.map(p => p[1])) - Math.min(...observed.map(p => p[1]))) / 2
  const aspect = 16 * height / (9 * width)
  const maxX = Math.min(spanX, spanY * aspect), maxY = maxX / aspect
  let small = 0, large = 1, suggested: Quad | undefined
  for (let step = 0; step < 18; step++) {
    const k = (small + large) / 2
    const [x, y] = center
    const rx = maxX * k, ry = maxY * k
    const rectangle: Quad = [[x-rx,y-ry],[x+rx,y-ry],[x+rx,y+ry],[x-rx,y+ry]]
    const normalized = rectangle.map(point => project(transform, point)) as unknown as Quad
    if (normalized.every(point => point.every(axis => axis >= .014 && axis <= .986))) {
      small = k
      const correction = normalized.map(point => project(currentWarp, point)) as unknown as Quad
      if (validQuad(correction)) suggested = correction
    } else large = k
  }
  if (!suggested) throw new Error('Розмістіть телефон ближче до центру проєкції та повторіть фото.')

  function luma(x: number, y: number) {
    const index = (Math.max(0, Math.min(height - 1, y)) * width + Math.max(0, Math.min(width - 1, x))) * 4
    return data[index] * .2126 + data[index + 1] * .7152 + data[index + 2] * .0722
  }
  const samples: Point[] = [[1/6,1/6],[5/6,1/6],[5/6,5/6],[1/6,5/6],[.5,.5]]
  const focusMeasured = samples.map(point => {
    const position = at(point)
    const x = Math.round(position[0] * width), y = Math.round(position[1] * height)
    const radius = Math.max(6, Math.round(Math.min(width, height) * .022))
    let laplacian = 0, gradient = 0
    for (let iy = y - radius; iy <= y + radius; iy++) for (let ix = x - radius; ix <= x + radius; ix++) {
      const p = luma(ix, iy), a = luma(ix-1, iy), b = luma(ix+1, iy), c = luma(ix, iy-1), d = luma(ix, iy+1)
      laplacian += Math.abs(4*p-a-b-c-d)
      gradient += Math.abs(b-a) + Math.abs(d-c)
    }
    return laplacian / Math.max(gradient, 1)
  })
  const max = Math.max(...focusMeasured, .003)
  const sharpness = focusMeasured.map(value => Math.round(value * 100 / max))
  const reference = at([.585,.585])
  const whiteX = Math.round(reference[0] * width), whiteY = Math.round(reference[1] * height)
  const white = luma(whiteX, whiteY)
  const pixel = (whiteY * width + whiteX) * 4
  const red = data[pixel], green = data[pixel + 1], blue = data[pixel + 2]
  const whiteCast = Math.max(red, green, blue) - Math.min(red, green, blue) < 12 ? 'нейтральний' :
    green > Math.max(red, blue) + 10 ? 'зеленуватий' : red - blue > 12 ? 'теплий' : blue - red > 12 ? 'холодний' : 'змішаний' 
  const levels = samples.slice(0, 4).map(point => {
    const center = at(point)
    const x = Math.round(center[0] * width), y = Math.round(center[1] * height)
    let highest = 0
    for (let j = -4; j <= 4; j++) for (let i = -4; i <= 4; i++) highest = Math.max(highest, luma(x+i,y+j))
    return highest
  })
  return { suggested, observed, sharpness, exposure: white > 247 ? 'Світлі ділянки близькі до пересвіту' :
    white < 120 ? 'Знімок темний' : 'Білий патч читається', whiteCast, evenness: Math.round((Math.max(...levels)-Math.min(...levels)) * 100 / 255) }
}
