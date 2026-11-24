import { useEffect, useRef, useState } from 'react'
import { AgentError, createDemoAgent, explain, realAgent } from './agent'
import type { Connection, Status, Volume } from './model'

export function useAgent(demo: boolean, version: number) {
  const [mock] = useState(createDemoAgent)
  const [status, setStatus] = useState<Status>()
  const [connection, setConnection] = useState<Connection>('loading')
  const [detail, setDetail] = useState('')
  const refresh = useRef<() => Promise<void>>(async () => {})
  const volumeRevision = useRef(0)
  const agent = demo ? mock : realAgent

  useEffect(() => {
    const lifetime = new AbortController()
    let socket: WebSocket | undefined
    let lastPush = 0
    let openedAt = 0
    let nextLiveAttempt = 0
    let retryDelay = 3000
    let reading = false
    let paired = false
    let pushCount = 0
    let hadStatus = false
    setStatus(undefined)
    setConnection('loading')
    setDetail('')

    function publish(value: Status) {
      if (lifetime.signal.aborted) return
      if (!value?.device?.model || !value.capabilities || !value.volume || !value.sleep || !value.media) {
        throw new AgentError('invalid_response', 0)
      }
      hadStatus = true
      paired = true
      setStatus(value)
      setConnection('connected')
      setDetail('')
    }

    function openLive() {
      if (demo || !paired || typeof WebSocket === 'undefined') return
      const now = Date.now()
      if (socket && socket.readyState < WebSocket.CLOSING) {
        if (now - Math.max(openedAt, lastPush) <= 8000) return
        socket.close()
      }
      if (now < nextLiveAttempt) return
      openedAt = now
      nextLiveAttempt = now + retryDelay
      retryDelay = Math.min(retryDelay * 2, 30000)
      const protocol = location.protocol === 'https:' ? 'wss://' : 'ws://'
      try {
        socket = new WebSocket(protocol + location.host + '/api/v1/live')
        socket.onmessage = event => {
          try {
            publish(JSON.parse(String(event.data)) as Status)
            lastPush = Date.now()
            retryDelay = 3000
            pushCount++
          } catch {
            socket?.close()
          }
        }
      } catch {
        // Status polling remains available.
      }
    }

    async function pull() {
      if (reading || lifetime.signal.aborted) return
      reading = true
      const received = pushCount
      const volumeAtRequest = volumeRevision.current
      try {
        const value = await agent.status(lifetime.signal)
        if (received === pushCount && volumeAtRequest === volumeRevision.current) publish(value)
        if (!lifetime.signal.aborted) openLive()
      } catch (error) {
        if (lifetime.signal.aborted || received !== pushCount) return
        if (error instanceof AgentError && error.status === 401) {
          paired = false
          hadStatus = false
          setStatus(undefined)
          setConnection('pairing')
          socket?.close()
        } else {
          setConnection(hadStatus ? 'disconnected' : 'error')
        }
        setDetail(explain(error))
      } finally {
        reading = false
      }
    }

    const timer = window.setInterval(() => {
      if (document.visibilityState !== 'visible') return
      if (Date.now() - lastPush > 3500) void pull()
    }, 2500)
    const wake = () => { if (document.visibilityState === 'visible') void pull() }
    refresh.current = pull
    void pull()
    document.addEventListener('visibilitychange', wake)
    window.addEventListener('online', wake)
    return () => {
      lifetime.abort()
      socket?.close()
      window.clearInterval(timer)
      document.removeEventListener('visibilitychange', wake)
      window.removeEventListener('online', wake)
    }
  }, [agent, demo, version])

  function reportVolume(volume: Volume) {
    volumeRevision.current++
    setStatus(previous => previous ? { ...previous, volume } : previous)
  }

  return { agent, status, connection, detail, refresh, reportVolume }
}
