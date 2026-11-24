const cacheName = 'beamdeck-shell-v1'
self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const shell = await fetch('/', { cache: 'reload' })
    if (!shell.ok) throw new Error('BeamDeck shell is unavailable')
    const html = await shell.clone().text()
    const assets = [...html.matchAll(/(?:src|href)="(\/assets\/[A-Za-z0-9_.-]+)"/g)].map(match => match[1])
    const cache = await caches.open(cacheName)
    await cache.addAll(assets)
    await cache.put('/', shell)
  })())
})
self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(
    keys.filter(key => key.startsWith('beamdeck-shell-') && key !== cacheName).map(key => caches.delete(key))
  )))
})
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url)
  if (event.request.method !== 'GET' || url.origin !== self.location.origin || url.pathname.startsWith('/api/')) return
  if (event.request.mode !== 'navigate' && !url.pathname.startsWith('/assets/')) return
  event.respondWith(fetch(event.request).then(async response => {
    if (response.ok) {
      const cache = await caches.open(cacheName)
      await cache.put(event.request.mode === 'navigate' ? '/' : event.request, response.clone())
    }
    return response
  }).catch(async () => (await caches.match(event.request.mode === 'navigate' ? '/' : event.request)) ?? Response.error()))
})
