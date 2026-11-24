import test from 'node:test'
import assert from 'node:assert/strict'
import { fullFrame, homography, inverse, moveCorner, project, validQuad, zoomOrMove } from '../.test-build/geometry.js'

const perspective = [[.12,.08],[.89,.14],[.92,.94],[.06,.85]]
const near = (actual, expected) => actual.forEach((axis, index) => assert.ok(Math.abs(axis - expected[index]) < 1e-9))

test('homography maps all four corners and round-trips interior points', () => {
  const mapping = homography(perspective)
  const back = inverse(mapping)
  fullFrame.forEach((point, index) => near(project(mapping, point), perspective[index]))
  near(project(back, project(mapping, [.21, .7])), [.21, .7])
  near(project(back, project(mapping, [.5, .5])), [.5, .5])
})

test('moving a corner keeps the other three fixed and stops before self-intersection', () => {
  const target = moveCorner(fullFrame, 0, [1.3, 1.4])
  assert.ok(validQuad(target))
  assert.ok(target[0][0] > .1)
  assert.deepEqual(target.slice(1), fullFrame.slice(1))
  assert.equal(validQuad([[0,0],[1,1],[1,0],[0,1]]), false)
  assert.equal(validQuad([[NaN,0],[1,0],[1,1],[0,1]]), false)
  assert.equal(validQuad([[0,0],[.01,0],[1,1],[0,1]]), false)
})

test('zoom and translation stay inside the native renderer bounds', () => {
  const inset = zoomOrMove(fullFrame, .8, 0, 0)
  const pushed = zoomOrMove(inset, 1, .9, -.7)
  assert.ok(validQuad(inset))
  assert.ok(validQuad(pushed))
  near(pushed[0], [.2, 0])
  near(pushed[2], [1, .8])
  assert.strictEqual(zoomOrMove(fullFrame, 1, 1, -1), fullFrame)
})
