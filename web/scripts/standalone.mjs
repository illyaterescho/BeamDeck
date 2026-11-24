import { readFile, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'

const dist = resolve('dist')
const index = await readFile(resolve(dist, 'index.html'), 'utf8')
const js = index.match(/<script type="module"[^>]*src="\/([^"]+)"[^>]*><\/script>/)
const css = index.match(/<link rel="stylesheet"[^>]*href="\/([^"]+)"[^>]*>/)
if (!js || !css) throw new Error('Expected one Vite script and stylesheet')
const script = await readFile(resolve(dist, js[1]), 'utf8')
const styles = await readFile(resolve(dist, css[1]), 'utf8')
const icon = (await readFile(resolve(dist, 'icon-192.png'))).toString('base64')
const output = index
  .replace(js[0], () => '<script type="module">' + script.replace(/<\/script/gi, '<\\/script') + '</script>')
  .replace(css[0], () => '<style>' + styles + '</style>')
  .replace(/<link rel="(?:manifest|apple-touch-icon)"[^>]*>\s*/g, '')
  .replace('/icon-192.png', 'data:image/png;base64,' + icon)
await writeFile(resolve(process.argv[2] ?? 'beamdeck-demo.html'), output)
