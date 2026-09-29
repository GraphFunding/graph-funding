import { formatEther } from 'viem'
import type { GraphState, TreeNode } from './chain'

const NS = 'http://www.w3.org/2000/svg'
const W = 1200
const ROOT = { x: 600, y: 640 }
/** Punto del eje central del que salen las dos ramas del medio (horquillas escalonadas). */
const AXIS = { x: 600, y: 490 }
/** Ancho del tronco pintado (tree-base.webp) donde se abre la copa, en unidades del viewBox. */
export const TRUNK = 96
export const ROOT_X = ROOT.x
export const ROOT_Y = ROOT.y
/** Suelo nevado de la base pintada, relativo a la copa: ahí se para el comité de la raíz. */
const GROUND = ROOT.y + 296

type P = { x: number; y: number }
type Placed = { node: TreeNode; at: P; from: P; parent?: Placed; share: number; local: number; angle: number; hot: boolean }

const el = <K extends keyof SVGElementTagNameMap>(tag: K, attrs: Record<string, string | number>, parent?: Element) => {
  const e = document.createElementNS(NS, tag)
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, String(v))
  parent?.appendChild(e)
  return e
}

const polar = (from: P, angleDeg: number, len: number): P => {
  const a = (angleDeg * Math.PI) / 180
  return { x: from.x + Math.sin(a) * len, y: from.y - Math.cos(a) * len }
}

const pct = (bps: number) => `${(bps / 100).toFixed(bps % 100 === 0 ? 0 : 2)}%`

export const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`

const heaviest = (kids: TreeNode[]) => kids.reduce((best, k, i) => (k.weight > kids[best].weight ? i : best), 0)

/** Raíz → ramas → proyectos. Con 4 ramas, las del medio nacen de un eje central (árbol, no escoba). */
function layout(root: TreeNode): { placed: Placed[]; axisHot: boolean; axisShare: number } {
  const placed: Placed[] = []
  const placedRoot: Placed = { node: root, at: ROOT, from: ROOT, share: 1, local: 1, angle: 0, hot: true }
  placed.push(placedRoot)
  const branches = root.children
  const n = branches.length
  const hotB = n ? heaviest(branches) : -1
  const staggered = n === 4
  let axisShare = 0
  branches.forEach((b, i) => {
    const bShare = b.weight / 10_000
    let angle: number
    let from: P
    let len: number
    if (staggered) {
      angle = [-62, -24, 24, 62][i]
      const middle = i === 1 || i === 2
      from = middle ? AXIS : ROOT
      len = middle ? 250 : 205
      if (middle) axisShare += bShare
    } else {
      angle = n === 1 ? 0 : -58 + (116 * i) / (n - 1)
      from = ROOT
      len = 240
    }
    const pb: Placed = { node: b, at: polar(from, angle, len), from, parent: placedRoot, share: bShare, local: bShare, angle, hot: i === hotB }
    placed.push(pb)
    const m = b.children.length
    const hotL = m ? heaviest(b.children) : -1
    const spread = m > 4 ? 14 : 17
    b.children.forEach((l, j) => {
      const la = angle + spread * (j - (m - 1) / 2)
      placed.push({
        node: l,
        at: polar(pb.at, la, 185),
        from: pb.at,
        parent: pb,
        share: bShare * (l.weight / 10_000),
        local: l.weight / 10_000,
        angle: la,
        hot: pb.hot && j === hotL,
      })
    })
  })
  const axisHot = staggered && (hotB === 1 || hotB === 2)
  return { placed, axisHot, axisShare }
}

const ctrl = (a: P, b: P): P => ({ x: a.x + (b.x - a.x) * 0.12, y: b.y + (a.y - b.y) * 0.32 })

const pointAt = (a: P, b: P, t: number): P => {
  const c = ctrl(a, b)
  return { x: (1 - t) ** 2 * a.x + 2 * (1 - t) * t * c.x + t ** 2 * b.x, y: (1 - t) ** 2 * a.y + 2 * (1 - t) * t * c.y + t ** 2 * b.y }
}

const limbPath = (a: P, b: P) => {
  const c = ctrl(a, b)
  return `M${a.x.toFixed(1)},${a.y.toFixed(1)} Q${c.x.toFixed(1)},${c.y.toFixed(1)} ${b.x.toFixed(1)},${b.y.toFixed(1)}`
}

/** Rama afinada: polígono a lo largo de la curva, de ancho w0 (base) a w1 (punta). */
const limbShape = (a: P, b: P, w0: number, w1: number) => {
  const c = ctrl(a, b)
  const left: string[] = []
  const right: string[] = []
  const N = 18
  for (let i = 0; i <= N; i++) {
    const t = i / N
    const x = (1 - t) ** 2 * a.x + 2 * (1 - t) * t * c.x + t ** 2 * b.x
    const y = (1 - t) ** 2 * a.y + 2 * (1 - t) * t * c.y + t ** 2 * b.y
    const dx = 2 * (1 - t) * (c.x - a.x) + 2 * t * (b.x - c.x)
    const dy = 2 * (1 - t) * (c.y - a.y) + 2 * t * (b.y - c.y)
    const len = Math.hypot(dx, dy) || 1
    const w = (w0 + (w1 - w0) * t) / 2
    left.push(`${(x - (dy / len) * w).toFixed(1)},${(y + (dx / len) * w).toFixed(1)}`)
    right.unshift(`${(x + (dy / len) * w).toFixed(1)},${(y - (dx / len) * w).toFixed(1)}`)
  }
  return `M${left.join(' L')} L${right.join(' L')} Z`
}

export type TreeHandles = { hotPaths: SVGPathElement[] }

/** Ubica la base pintada para que su tronco (13.5% del ancho, centrado al 55.5%) sea el tronco del árbol vivo. */
export function placePlate(svg: SVGSVGElement, plate: HTMLElement) {
  const [vx, vy, vw] = (svg.dataset.vb ?? `0,0,${W}`).split(',').map(Number)
  const box = svg.getBoundingClientRect()
  const scale = box.width / vw
  const plateW = (TRUNK * scale) / 0.135
  const plateH = plateW / (2688 / 1520)
  const x = (ROOT_X - vx) * scale - 0.555 * plateW
  const top = (ROOT_Y - vy - 30) * scale
  const wrapEl = svg.parentElement as HTMLElement
  const wrap = wrapEl.getBoundingClientRect()
  const offX = box.left - wrap.left + wrapEl.scrollLeft
  const offY = box.top - wrap.top
  plate.style.width = `${plateW}px`
  plate.style.height = `${plateH}px`
  plate.style.left = `${x + offX}px`
  plate.style.top = `${top + offY}px`
  wrapEl.style.paddingBottom = `${Math.max(0, top + plateH - box.height)}px`
}

/** Centro horizontal del tronco en px dentro del SVG (para centrar el deslizamiento en móvil). */
export function trunkCenterPx(svg: SVGSVGElement) {
  const [vx, , vw] = (svg.dataset.vb ?? `0,0,${W}`).split(',').map(Number)
  const box = svg.getBoundingClientRect()
  return (ROOT_X - vx) * (box.width / vw)
}

export function renderTree(svg: SVGSVGElement, tip: HTMLElement, state: GraphState): TreeHandles {
  svg.replaceChildren()
  const { placed, axisHot, axisShare } = layout(state.tree)
  const xs = placed.map((p) => p.at.x)
  const top = Math.min(...placed.map((p) => p.at.y)) - 120
  const left = Math.min(...xs) - 175
  const right = Math.max(...xs) + 175
  const bottom = GROUND + 34
  svg.setAttribute('viewBox', `${left} ${top} ${right - left} ${bottom - top}`)
  svg.dataset.vb = `${left},${top},${right - left}`
  const gLimbs = el('g', { class: 'limbs' }, svg)
  const gHot = el('g', {}, svg)
  const gSeats = el('g', {}, svg)
  const gLabels = el('g', {}, svg)
  const gClimax = el('g', { class: 'climax' }, svg)
  const gHits = el('g', {}, svg)
  const hotPaths: SVGPathElement[] = []
  const root = placed[0]

  // anchos: la copa nace del ancho del tronco pintado y se afina hacia cada proyecto
  const endW = (p: Placed) => (p.node.recipient ? 4 + 9 * Math.sqrt(p.local) : 12 + 26 * Math.sqrt(p.share))
  const startW = (p: Placed) =>
    p.parent === root
      ? Math.max(20, TRUNK * Math.min(0.62, Math.sqrt(p.share) * 0.95))
      : Math.max(6, endW(p.parent!) * Math.min(0.85, Math.sqrt(p.local) * 1.1))

  // eje central: continúa el tronco hasta la horquilla de las ramas del medio
  if (axisShare > 0) {
    const w0 = TRUNK * Math.min(0.7, Math.sqrt(axisShare) * 1.05)
    const w1 = Math.max(22, TRUNK * Math.sqrt(axisShare) * 0.7)
    const d = limbShape(ROOT, AXIS, w0, w1)
    el('path', { d, class: 'limb' }, gLimbs)
    el('path', { d, class: 'limb-tex' }, gLimbs)
  }

  // el camino de la plata sube por el tronco pintado, del lado de la rama financiada
  const hotBranch = placed.find((p) => p.parent === root && p.hot)
  const side = hotBranch && hotBranch.angle < 0 ? -1 : 1
  hotPaths.push(
    el('path', { d: `M${ROOT.x + side * 22},${GROUND - 8} C${ROOT.x + side * 30},${ROOT.y + 170} ${ROOT.x + side * 14},${ROOT.y + 60} ${ROOT.x + side * 6},${ROOT.y}`, class: 'limb-hot', 'stroke-width': 15 }, gHot),
  )
  if (axisHot) hotPaths.push(el('path', { d: limbPath(ROOT, AXIS), class: 'limb-hot', 'stroke-width': 13 }, gHot))

  for (const p of placed) {
    if (!p.parent) continue
    const d = limbShape(p.from, p.at, startW(p), endW(p))
    el('path', { d, class: 'limb' }, gLimbs)
    el('path', { d, class: 'limb-tex' }, gLimbs)
    if (p.hot) hotPaths.push(el('path', { d: limbPath(p.from, p.at), class: 'limb-hot', 'stroke-width': Math.max(5, endW(p) * 0.5) }, gHot))
  }

  const seatW = 38
  const seatH = 86
  const size = 5
  for (const p of placed) {
    const isBranch = !p.node.recipient
    if (isBranch && p.node.children.length >= 2) {
      // comité de la bifurcación: parados a lo largo de su rama (el de la raíz, en la nieve al pie del tronco).
      // Antes del primer sorteo son asientos vacíos en contorno punteado.
      const members = p.node.committee ?? []
      const voted = new Set((p.node.votes ?? []).map((v) => v.voter.toLowerCase()))
      const seats = members.length || size
      for (let s = 0; s < seats; s++) {
        const foot =
          p === root
            ? { x: ROOT.x + (s - (seats - 1) / 2) * 58 + (s >= seats / 2 ? 70 : -70), y: GROUND - (s % 2) * 6 }
            : pointAt(p.from, p.at, 0.46 + (0.46 * s) / Math.max(1, seats - 1))
        const m = members[s]
        const href = !m ? '/assets/keeper-empty.webp' : voted.has(m.toLowerCase()) ? '/assets/keeper-lit.webp' : '/assets/keeper-blue.webp'
        el('image', { href, x: foot.x - seatW / 2, y: foot.y - seatH + 6, width: seatW, height: seatH, class: m ? 'member' : 'seat' }, gSeats)
      }
    }
    if (isBranch && p.parent) {
      const t = el('text', { x: p.at.x, y: p.at.y + 38, 'text-anchor': 'middle', class: 'label-branch halo' }, gLabels)
      t.textContent = p.node.name.toUpperCase()
      const w = el('text', { x: p.at.x, y: p.at.y + 57, 'text-anchor': 'middle', class: `pct halo${p.hot ? ' hot' : ''}` }, gLabels)
      w.textContent = pct(p.node.weight)
    }
    if (!isBranch) {
      el(
        'use',
        { href: '#leaf', x: -16, y: -8, width: 32, height: 16, class: `leaf${p.hot ? ' hot' : ''}`, transform: `translate(${p.at.x.toFixed(1)},${p.at.y.toFixed(1)}) rotate(${(p.angle - 90).toFixed(1)})` },
        gLabels,
      )
      const rightSide = p.at.x >= ROOT.x
      const off = polar(p.at, p.angle, 22)
      const anchor = Math.abs(p.angle) < 12 ? 'middle' : rightSide ? 'start' : 'end'
      const ly = Math.abs(p.angle) < 12 ? off.y - 8 : off.y + 4
      const t = el('text', { x: off.x, y: ly, 'text-anchor': anchor, class: 'label halo' }, gLabels)
      t.textContent = p.node.name
      const w = el('text', { x: off.x, y: ly + 15, 'text-anchor': anchor, class: `pct halo${p.hot ? ' hot' : ''}` }, gLabels)
      w.textContent = pct(p.node.weight)
      if (p.hot) {
        // clímax: el Keeper de este proyecto enciende su farol cuando el camino termina de dibujarse
        const kx = p.at.x + (rightSide ? -6 : 6)
        el('image', { href: '/assets/keeper-lit.webp', x: kx - 24, y: p.at.y - 118, width: 48, height: 108 }, gClimax)
        const cl = el('text', { x: kx, y: p.at.y - 128, 'text-anchor': 'middle', class: 'climax-label halo' }, gClimax)
        cl.textContent = `${p.node.name.toUpperCase()} · ${(p.share * 100).toFixed(0)}% OF ALL MONEY`
      }
    }
    const hit = el('circle', { cx: p.at.x, cy: p === root ? ROOT.y + 20 : p.at.y, r: isBranch ? 46 : 28, class: 'node-hit', tabindex: 0 }, gHits)
    const show = () => showTip(tip, svg, p, state)
    hit.addEventListener('mouseenter', show)
    hit.addEventListener('focus', show)
    hit.addEventListener('mouseleave', () => (tip.hidden = true))
    hit.addEventListener('blur', () => (tip.hidden = true))
    if (p.node.recipient) {
      hit.addEventListener('click', () => window.open(`https://etherscan.io/address/${p.node.recipient}`, '_blank', 'noopener'))
    }
  }
  return { hotPaths }
}

function showTip(tip: HTMLElement, svg: SVGSVGElement, p: Placed, state: GraphState) {
  const n = p.node
  const lines: string[] = []
  if (n.recipient) {
    lines.push(`<li><code>${short(n.recipient)}</code> · open on Etherscan</li>`)
    lines.push(`<li>Share of all money: ${(p.share * 100).toFixed(2)}%</li>`)
    if (state.live) lines.push(`<li>Owed now: ${formatEther(n.owed ?? 0n)} ETH</li>`)
    if (n.proposer) lines.push(`<li>Proposed by <code>${short(n.proposer)}</code></li>`)
  } else {
    for (const c of n.children) lines.push(`<li>${escapeHtml(c.name)} · ${pct(c.weight)}</li>`)
    const members = n.committee ?? []
    if (!state.live || state.epoch === 0) lines.push('<li>Committee: drawn from the first epoch</li>')
    else if (!members.length) lines.push(`<li>Epoch ${state.epoch}: no committee drawn yet</li>`)
    else {
      const voted = new Set((n.votes ?? []).map((v) => v.voter.toLowerCase()))
      lines.push(`<li>Epoch ${state.epoch} committee:</li>`)
      for (const m of members) lines.push(`<li><code>${short(m)}</code> ${voted.has(m.toLowerCase()) ? 'voted' : 'waiting'}</li>`)
    }
  }
  tip.innerHTML = `<h4>${escapeHtml(n.name)}</h4><ul>${lines.join('')}</ul>`
  const box = svg.getBoundingClientRect()
  const wrap = svg.parentElement!.getBoundingClientRect()
  const [vx, vy, vw] = (svg.dataset.vb ?? `0,0,${W}`).split(',').map(Number)
  const sx = box.width / vw
  const x = box.left - wrap.left + (p.at.x - vx) * sx
  const y = box.top - wrap.top + (p.at.y - vy) * sx
  tip.hidden = false
  const leftPx = Math.min(Math.max(8, x + 24), wrap.width - tip.offsetWidth - 8)
  tip.style.left = `${leftPx}px`
  tip.style.top = `${Math.max(8, y - tip.offsetHeight - 20)}px`
}

const escapeHtml = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!)
