export type Point = readonly [number, number]
export type Quad = readonly [Point, Point, Point, Point]
export type Geometry = { corners: Quad; mode: 'manual' | 'auto' }
type Matrix = readonly [number, number, number, number, number, number, number, number, number]

export const fullFrame: Quad = [[0, 0], [1, 0], [1, 1], [0, 1]]
export const identityGeometry: Geometry = { corners: fullFrame, mode: 'manual' }

export function validQuad(value: unknown): value is Quad {
  if (!Array.isArray(value) || value.length !== 4 || !value.every(point =>
    Array.isArray(point) && point.length === 2 && point.every(axis => typeof axis === 'number' && axis >= 0 && axis <= 1),
  )) return false
  return value.every((a, index) => {
    const b = value[(index + 1) % 4], c = value[(index + 2) % 4]
    return Math.hypot(b[0] - a[0], b[1] - a[1]) >= .09 &&
      (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]) >= .006
  })
}

const constrain = (value: number) => Math.max(0, Math.min(1, value))

export function moveCorner(corners: Quad, index: number, requested: Point): Quad {
  const desired: Point = [constrain(requested[0]), constrain(requested[1])]
  if (desired[0] === corners[index][0] && desired[1] === corners[index][1]) return corners
  const make = (point: Point) => corners.map((corner, position) => position === index ? point : corner) as unknown as Quad
  if (validQuad(make(desired))) return make(desired)
  const [x, y] = corners[index]
  let min = 0, max = 1
  for (let step = 0; step < 12; step++) {
    const fraction = (max + min) / 2
    if (validQuad(make([x + (desired[0] - x) * fraction, y + (desired[1] - y) * fraction]))) min = fraction
    else max = fraction
  }
  return make([x + (desired[0] - x) * min, y + (desired[1] - y) * min])
}

export function homography(corners: Quad): Matrix {
  const [[x0, y0], [x1, y1], [x2, y2], [x3, y3]] = corners
  const dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
  const dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
  const determinant = dx1 * dy2 - dx2 * dy1
  if (Math.abs(determinant) < 1e-12) throw new Error('Singular homography')
  const g = (dx3 * dy2 - dx2 * dy3) / determinant
  const h = (dx1 * dy3 - dx3 * dy1) / determinant
  return [x1 - x0 + g * x1, x3 - x0 + h * x3, x0, y1 - y0 + g * y1, y3 - y0 + h * y3, y0, g, h, 1]
}

export function inverse([a, b, c, d, e, f, g, h, i]: Matrix): Matrix {
  const adj: Matrix = [e*i-f*h, c*h-b*i, b*f-c*e, f*g-d*i, a*i-c*g, c*d-a*f, d*h-e*g, b*g-a*h, a*e-b*d]
  const determinant = a * adj[0] + b * adj[3] + c * adj[6]
  if (Math.abs(determinant) < 1e-12) throw new Error('Singular inverse')
  return adj.map(value => value / determinant) as unknown as Matrix
}

export function project([a, b, c, d, e, f, g, h, i]: Matrix, [x, y]: Point): Point {
  const w = g * x + h * y + i
  return [(a * x + b * y + c) / w, (d * x + e * y + f) / w]
}

export function zoomOrMove(corners: Quad, scale: number, x: number, y: number): Quad {
  const cx = corners.reduce((sum, point) => sum + point[0], 0) / 4
  const cy = corners.reduce((sum, point) => sum + point[1], 0) / 4
  const scaled = corners.map(point => [cx + (point[0] - cx) * scale, cy + (point[1] - cy) * scale]) as unknown as Quad
  const shift = (index: 0 | 1, delta: number) => Math.max(-Math.min(...scaled.map(p => p[index])),
    Math.min(1 - Math.max(...scaled.map(p => p[index])), delta))
  const dx = shift(0, x), dy = shift(1, y)
  const changed = scaled.map(point => [constrain(point[0] + dx), constrain(point[1] + dy)]) as unknown as Quad
  return validQuad(changed) && changed.some((point, i) => point[0] !== corners[i][0] || point[1] !== corners[i][1]) ? changed : corners
}
