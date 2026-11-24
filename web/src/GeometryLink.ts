import { useEffect, useRef, useState } from 'react'
import type { Geometry } from './geometry'

type SaveState = 'local' | 'connecting' | 'ready' | 'saving' | 'saved' | 'error'

export function useGeometryLink(active: boolean, demo: boolean, fallback: (geometry: Geometry) => Promise<boolean>) {
  const [state, setState] = useState<SaveState>(demo ? 'local' : 'connecting')
  const transport = useRef<WebSocket | null>(null)
  const serial = useRef(0)
  const pending = useRef<number | null>(null)
  const previewTimer = useRef<number | undefined>(undefined)
  const lastCommit = useRef(0)
  const commitTimer = useRef<number | undefined>(undefined)
  const ackTimer = useRef<number | undefined>(undefined)
  const queued = useRef<Geometry | null>(null)
  const lastPreview = useRef(0)

  useEffect(() => {
    if (!active || demo || typeof WebSocket === 'undefined') {
      setState('local')
      return
    }
    let disposed = false
    let retry: number | undefined
    function open() {
      setState('connecting')
      const protocol = location.protocol === 'https:' ? 'wss://' : 'ws://'
      const socket = new WebSocket(protocol + location.host + '/api/v1/geometry/live')
      transport.current = socket
      socket.onopen = () => { if (!disposed) setState('ready') }
      socket.onmessage = event => {
        const reply = JSON.parse(String(event.data)) as { id: number; accepted: boolean }
        if (reply.id !== pending.current || disposed) return
        pending.current = null
        window.clearTimeout(ackTimer.current)
        setState(reply.accepted ? 'saved' : 'error')
      }
      socket.onclose = () => {
        if (disposed) return
        if (transport.current === socket) transport.current = null
        if (pending.current !== null) {
          pending.current = null
          window.clearTimeout(ackTimer.current)
          setState('error')
        } else setState('local')
        retry = window.setTimeout(open, 3500)
      }
    }
    open()
    return () => {
      disposed = true
      pending.current = null
      queued.current = null
      transport.current?.close()
      transport.current = null
      window.clearTimeout(retry)
      window.clearTimeout(previewTimer.current)
      previewTimer.current = undefined
      window.clearTimeout(ackTimer.current)
      window.clearTimeout(commitTimer.current)
    }
  }, [active, demo])

  function emit(geometry: Geometry, commit: boolean) {
    const socket = transport.current
    if (!socket || socket.readyState !== WebSocket.OPEN || socket.bufferedAmount > 2048) return false
    const id = ++serial.current
    try { socket.send(JSON.stringify({ ...geometry, id, commit })) } catch { return false }
    if (commit) {
      pending.current = id
      lastCommit.current = performance.now()
      window.clearTimeout(ackTimer.current)
      ackTimer.current = window.setTimeout(() => {
        if (pending.current !== id) return
        pending.current = null
        setState('error')
      }, 4000)
    }
    return true
  }

  function preview(geometry: Geometry) {
    queued.current = geometry
    setState(previous => previous === 'saved' ? 'ready' : previous)
    if (previewTimer.current !== undefined) return
    const flush = () => {
      previewTimer.current = undefined
      const value = queued.current
      if (value) {
        emit(value, false)
        lastPreview.current = performance.now()
        queued.current = null
      }
    }
    const wait = 50 - (performance.now() - lastPreview.current)
    if (wait <= 0) flush()
    else previewTimer.current = window.setTimeout(flush, wait)
  }

  async function save(geometry: Geometry, confirmed = false) {
    window.clearTimeout(previewTimer.current)
    previewTimer.current = undefined
    queued.current = null
    pending.current = null
    window.clearTimeout(ackTimer.current)
    window.clearTimeout(commitTimer.current)
    if (!active && !demo) { setState('local'); return false }
    setState('saving')
    async function commit() {
      if (!confirmed && emit(geometry, true)) return true
      const applied = await fallback(geometry)
      setState(applied ? 'saved' : 'error')
      return applied
    }
    const delay = 145 - (performance.now() - lastCommit.current)
    if (!confirmed && transport.current?.readyState === WebSocket.OPEN && delay > 0) {
      commitTimer.current = window.setTimeout(() => void commit(), delay)
      return true
    }
    return commit()
  }

  return { state, preview, save }
}
