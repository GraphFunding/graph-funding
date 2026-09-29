import './style.css'
import gsap from 'gsap'
import { ScrollTrigger } from 'gsap/ScrollTrigger'
import Lenis from 'lenis'
import { formatEther, formatUnits, isAddress, parseUnits, type Address } from 'viem'
import { actions, connect, keeperView, readState, type GraphState, type TreeNode } from './chain'
import { chapter, config, deployed } from './config'
import { placePlate, renderTree, short, trunkCenterPx } from './tree'
import sources from './data/sources.json'

gsap.registerPlugin(ScrollTrigger)
const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches
const $ = <T extends Element = HTMLElement>(s: string) => document.querySelector<T>(s)!
const $$ = <T extends Element = HTMLElement>(s: string) => [...document.querySelectorAll<T>(s)]

// ------------------------------------------------------------------ tinta riso: dos pasadas con grano
function inkTitles() {
  $$('.riso').forEach((h) => {
    if (h.querySelector('.ink')) return
    h.dataset.text = h.innerHTML.replace(/<br\s*\/?>/gi, '\n').replace(/<[^>]+>/g, '')
    h.innerHTML = `<span class="ink">${h.innerHTML}</span>`
  })
}
inkTitles()

// cinta en las cuatro esquinas de cada afiche
$$('.poster-art').forEach((a) => a.insertAdjacentHTML('beforeend', '<i class="tape bl"></i><i class="tape br"></i>'))

// ------------------------------------------------------------------ links estáticos
$$<HTMLAnchorElement>('[data-chapter-link]').forEach((a) => {
  a.href = chapter(Number(a.dataset.chapterLink))
  a.target = '_blank'
  a.rel = 'noopener'
})
$$<HTMLAnchorElement>('[data-book]').forEach((a) => {
  a.href = config.book
  a.target = '_blank'
  a.rel = 'noopener'
})
$$<HTMLAnchorElement>('[data-link="github"]').forEach((a) => {
  if (config.github) {
    a.href = config.github
    a.target = '_blank'
    a.rel = 'noopener'
  }
})
$$<HTMLAnchorElement>('[data-link="x"]').forEach((a) => {
  if (config.x) a.href = config.x
  else a.hidden = true
})
$$<HTMLAnchorElement>('[data-link="genesis"]').forEach((a) => {
  if (config.github) {
    a.href = `${config.github}/blob/main/contracts/script/genesis.json`
    a.target = '_blank'
    a.rel = 'noopener'
  }
})
// los 14 destinatarios con su fuente oficial (del génesis; el árbol en vivo usa la cadena)
function paintRecipients(tree: TreeNode) {
  const rows: string[] = []
  for (const b of tree.children) {
    for (const l of b.children) {
      if (!l.recipient) continue
      const src = (sources as Record<string, string>)[l.recipient.toLowerCase()]
      rows.push(
        `<tr><td>${l.name}</td><td>${b.name}</td><td><a href="https://etherscan.io/address/${l.recipient}" target="_blank" rel="noopener"><code>${short(l.recipient)}</code></a></td><td>${src ? `<a href="${src}" target="_blank" rel="noopener">official page</a>` : 'proposed on-chain'}</td></tr>`,
      )
    }
  }
  $('[data-recipients] tbody').innerHTML = rows.join('')
}

// talón de la CA
if (config.token) {
  $('[data-ca-hero]').textContent = config.token
  const copy = $<HTMLButtonElement>('[data-copy-ca]')
  copy.disabled = false
  copy.addEventListener('click', async () => {
    await navigator.clipboard.writeText(config.token).catch(() => {})
    copy.textContent = 'Copied'
    setTimeout(() => (copy.textContent = 'Copy'), 1400)
  })
}

// ------------------------------------------------------------------ smooth scroll
if (!reduced) {
  const lenis = new Lenis({ lerp: 0.11 })
  lenis.on('scroll', ScrollTrigger.update)
  gsap.ticker.add((t) => lenis.raf(t * 1000))
  gsap.ticker.lagSmoothing(0)
  $$<HTMLAnchorElement>('a[href^="#"]').forEach((a) =>
    a.addEventListener('click', (e) => {
      const id = a.getAttribute('href')!
      if (id.length > 1 && document.querySelector(id)) {
        e.preventDefault()
        lenis.scrollTo(id, { offset: -10 })
      }
    }),
  )
}

// ------------------------------------------------------------------ estado
let state: GraphState
const eth = (v: bigint) => `${Number(formatEther(v)).toLocaleString('en-US', { maximumFractionDigits: 4 })} ETH`
const gf = (v: bigint) => Number(formatUnits(v, 18)).toLocaleString('en-US', { maximumFractionDigits: 0 })

function branches(t: TreeNode): TreeNode[] {
  const out: TreeNode[] = []
  const walk = (n: TreeNode) => {
    if (!n.recipient) {
      out.push(n)
      n.children.forEach(walk)
    }
  }
  walk(t)
  return out
}

function paintStatus() {
  const chipNav = $('[data-status]')
  const chipHero = $('[data-status-hero]')
  if (!state.live) {
    chipNav.textContent = 'Genesis tree · not deployed yet'
    chipHero.textContent = 'genesis tree below'
    return
  }
  if (state.epoch === 0) {
    chipNav.textContent = 'Deployed · epochs not started'
    chipHero.textContent = 'the first epoch starts soon'
    return
  }
  const left = Math.max(0, state.nextAdvanceAt - Math.floor(Date.now() / 1000))
  const hh = String(Math.floor(left / 3600)).padStart(2, '0')
  const mm = String(Math.floor((left % 3600) / 60)).padStart(2, '0')
  const ss = String(left % 60).padStart(2, '0')
  const t = left ? `${hh}:${mm}:${ss}` : 'due now'
  chipNav.textContent = `Epoch ${state.epoch} · next split ${t}`
  chipHero.textContent = `epoch ${state.epoch} · next split in ${t}`
  $('[data-k="next"]').textContent = t
}

function paintCounters() {
  const k = (key: string, v: string) => ($(`[data-k="${key}"]`).textContent = v)
  // antes del deploy no se muestran ceros: se muestra el estado génesis
  $('[data-counters]').hidden = !state.live
  $('[data-genesis-strip]').hidden = state.live
  const title = $('[data-graph-title]')
  const want = state.live ? 'The graph,\nlive' : 'The graph,\nat genesis'
  if (title.dataset.text !== want) {
    title.dataset.text = want
    title.innerHTML = `<span class="ink">${want.replace('\n', '<br />')}</span>`
  }
  if (!state.live) {
    k('harvestable', 'not launched yet')
    return
  }
  k('pool', eth(state.pool))
  k('owed', eth(state.totalOwed))
  k('epoch', state.epoch ? String(state.epoch) : 'not started')
  k('keepers', String(state.keepers))
  k('harvestable', eth(state.harvestable))
  $('[data-genesis-note]').hidden = state.epoch > 0
}

function paintAddresses() {
  if (!deployed()) return
  const row = (label: string, a: string) =>
    `<dt>${label}</dt><dd>${a ? `<a href="https://etherscan.io/address/${a}" target="_blank" rel="noopener">${a}</a>` : 'not launched yet'}</dd>`
  $('[data-addrs]').innerHTML =
    row('GraphFund', config.graphFund) + row('KeeperStaking', config.staking) + row('KeeperBadge', config.badge) + row('$GRAPHFUND', config.token)
  if (config.token) $('[data-ca]').innerHTML = `$GRAPHFUND <code>${config.token}</code>`
}

let hotTween: gsap.core.Tween | null = null
function paintTree() {
  const svg = $<SVGSVGElement>('svg.tree')
  const { hotPaths } = renderTree(svg, $('.tree-tip'), state)
  const plate = $('.tree-plate')
  const wrap = svg.parentElement as HTMLElement
  const layoutTree = () => {
    placePlate(svg, plate)
    // en móvil el árbol se desliza: arrancar centrado en el tronco
    if (wrap.scrollWidth > wrap.clientWidth + 4) {
      const svgLeft = svg.getBoundingClientRect().left - wrap.getBoundingClientRect().left + wrap.scrollLeft
      wrap.scrollLeft = svgLeft + trunkCenterPx(svg) - wrap.clientWidth / 2
    }
  }
  layoutTree()
  window.onresize = () => {
    layoutTree()
    ScrollTrigger.refresh()
  }
  svg.classList.toggle('is-climax', reduced)
  // el camino financiado se dibuja con el scroll (wow Tier-1, catálogo C3)
  hotTween?.scrollTrigger?.kill()
  hotTween?.kill()
  const lens = hotPaths.map((p) => p.getTotalLength())
  hotPaths.forEach((p, i) => {
    p.style.strokeDasharray = `${lens[i]}`
    p.style.strokeDashoffset = reduced ? '0' : `${lens[i]}`
  })
  if (reduced) return
  const total = lens.reduce((a, b) => a + b, 0)
  const progress = { v: 0 }
  hotTween = gsap.to(progress, {
    v: 1,
    ease: 'none',
    onUpdate: () => {
      let left = progress.v * total
      hotPaths.forEach((p, i) => {
        const drawn = Math.max(0, Math.min(lens[i], left))
        p.style.strokeDashoffset = String(lens[i] - drawn)
        left -= lens[i]
      })
      // clímax: cuando la plata llega a la hoja, su Keeper enciende el farol
      svg.classList.toggle('is-climax', progress.v > 0.985)
    },
    scrollTrigger: { trigger: '.tree-wrap', start: 'top 80%', end: 'center 40%', scrub: 0.6 },
  })
}

function paintProposeParents() {
  const sel = $<HTMLSelectElement>('[data-in="parent"]')
  // las propuestas cuelgan de una rama, nunca de la raíz (el contrato revierte BadParent)
  sel.innerHTML = branches(state.tree)
    .filter((b) => b.id !== 0)
    .map((b) => `<option value="${b.id}">${b.name}</option>`)
    .join('')
}

async function refresh() {
  try {
    state = await readState()
  } catch (e) {
    console.error(e)
    state = await readState().catch(() => state)
  }
  paintStatus()
  paintCounters()
  paintAddresses()
  paintTree()
  paintRecipients(state.tree)
  paintProposeParents()
  paintMe()
}

// ------------------------------------------------------------------ Keeper app
let me: Awaited<ReturnType<typeof connect>> | null = null
const msg = (t: string) => ($('[data-msg]').textContent = t)
const amountIn = () => {
  const raw = $<HTMLInputElement>('[data-in="amount"]').value.replace(/[, _]/g, '')
  if (!raw) throw new Error('Enter an amount of $GRAPHFUND.')
  return parseUnits(raw, 18)
}

function sliderRows(node: TreeNode, disabled: boolean) {
  return node.children
    .map(
      (c, i) =>
        `<label class="slider"><span>${c.name}</span><input type="range" min="0" max="10000" step="50" value="${c.weight}" data-slider="${i}" ${disabled ? 'disabled' : ''} /><output>${(c.weight / 100).toFixed(1)}%</output></label>`,
    )
    .join('')
}

async function paintMe() {
  const writes = $$<HTMLButtonElement>('[data-act="stake"],[data-act="unstake"],[data-act="leave"],[data-act="propose"],[data-act="vote"]')
  const ready = deployed() && !!config.token
  writes.forEach((b) => (b.disabled = !ready || !me))
  // SPECIMEN: antes del deploy el formulario muestra un ejemplar real con la rama más pesada del génesis
  const specimen = !ready
  $('[data-specimen]').hidden = !specimen
  const drawnBox = $('[data-me="drawn"]')
  if (specimen) {
    const node = branches(state.tree).filter((b) => b.id !== 0).sort((a, b) => b.weight - a.weight)[0]
    drawnBox.hidden = false
    $('[data-me="drawn-name"]').textContent = node.name
    $('[data-me="sliders"]').innerHTML = sliderRows(node, true)
    msg(deployed() ? 'Staking opens when $GRAPHFUND launches.' : 'Specimen. This form goes live with the contracts.')
  }
  if (!me) {
    if (!specimen) drawnBox.hidden = true
    return
  }
  $('[data-me="address"]').textContent = short(me.account)
  $<HTMLButtonElement>('[data-act="harvest"]').hidden = !(config.creator && me.account.toLowerCase() === config.creator.toLowerCase())
  const v = await keeperView(me.account, state.epoch, branches(state.tree).map((b) => b.id))
  if (!v) return
  $('[data-me="stake"]').textContent = `${gf(v.stake)} GRAPHFUND${v.leaving ? ' · leaving' : ''}`
  $<HTMLButtonElement>('[data-act="leave"]').hidden = v.stake === 0n || v.leaving
  $('[data-me="balance"]').textContent = `${gf(v.balance)} GRAPHFUND`
  // la chance es sobre el peso del sorteo (stakes bajo el mínimo o saliendo no cuentan), no sobre todo lo bloqueado
  const total = state.totalWeight
  $('[data-me="chance"]').textContent = total > 0n && v.weight > 0n ? `${((Number(v.weight) / Number(total)) * 100).toFixed(2)}%` : '0%'
  const drawn = $('[data-me="drawn"]')
  drawn.hidden = v.drawnFor.length === 0
  if (v.drawnFor.length) {
    const node = branches(state.tree).find((b) => b.id === v.drawnFor[0])!
    $('[data-me="drawn-name"]').textContent = node.name
    $('[data-me="sliders"]').innerHTML = sliderRows(node, false)
    $$<HTMLInputElement>('[data-slider]').forEach((s) =>
      s.addEventListener('input', () => (s.nextElementSibling!.textContent = `${(Number(s.value) / 100).toFixed(1)}%`)),
    )
    drawn.dataset.node = String(node.id)
  }
}

const act = async (fn: () => Promise<unknown>, pending: string, done: string) => {
  try {
    msg(pending)
    await fn()
    msg(done)
    await refresh()
  } catch (e) {
    msg((e as Error).message.split('\n')[0].slice(0, 200))
  }
}

$('[data-act="connect"]').addEventListener('click', () =>
  act(async () => {
    me = await connect()
    $('[data-act="connect"]').textContent = short(me.account)
  }, 'Waiting for your wallet…', 'Connected.'),
)
$('[data-act="stake"]').addEventListener('click', () => me && act(() => actions.stake(me!, amountIn()), 'Approve and stake in your wallet…', 'Staked. You enter the next draw.'))
$('[data-act="unstake"]').addEventListener('click', () => me && act(() => actions.unstake(me!, amountIn()), 'Confirm in your wallet…', 'Unstaked.'))
$('[data-act="leave"]').addEventListener('click', () =>
  me && act(() => actions.leave(me!), 'Confirm in your wallet…', 'You are out of the next draws. Unstake once your seat ends.'),
)
$('[data-act="vote"]').addEventListener('click', () => {
  if (!me) return
  const raw = $$<HTMLInputElement>('[data-slider]').map((s) => Number(s.value))
  const sum = raw.reduce((a, b) => a + b, 0) || 1
  const bps = raw.map((v) => Math.floor((v * 10_000) / sum))
  bps[bps.indexOf(Math.max(...bps))] += 10_000 - bps.reduce((a, b) => a + b, 0)
  act(() => actions.vote(me!, Number($('[data-me="drawn"]').dataset.node), bps), 'Confirm your vote in your wallet…', 'Vote cast. Your badge is minted.')
})
$('[data-act="propose"]').addEventListener('click', () => {
  if (!me) return
  const recipient = $<HTMLInputElement>('[data-in="precipient"]').value.trim()
  const name = $<HTMLInputElement>('[data-in="pname"]').value.trim()
  if (!isAddress(recipient)) return msg('That donation address is not valid.')
  if (!name) return msg('Give the project a name.')
  act(
    () => actions.propose(me!, Number($<HTMLSelectElement>('[data-in="parent"]').value), recipient as Address, name, parseUnits('1000000', 18)),
    'Approve the deposit and propose in your wallet…',
    'Proposed. It enters the tree at the next epoch.',
  )
})
$('[data-act="harvest"]').addEventListener('click', () => me && act(() => actions.harvest(me!), 'Confirm the claim in your wallet…', 'Harvested into Graph Funding.'))

// ------------------------------------------------------------------ entradas (screenshot-safe: sólo transform)
if (!reduced) {
  gsap.from('.hero-copy > *', { y: 26, duration: 0.9, ease: 'power3.out', stagger: 0.08, clearProps: 'transform' })
  $$('.poster').forEach((p, i) =>
    gsap.from(p, { y: 60, rotate: i % 2 ? 2 : -2, duration: 1, ease: 'power3.out', clearProps: 'transform', scrollTrigger: { trigger: '.posters', start: 'top 85%' } }),
  )
  gsap.from('.steps li', { y: 40, duration: 0.8, ease: 'power3.out', stagger: 0.1, clearProps: 'transform', scrollTrigger: { trigger: '.steps', start: 'top 80%' } })
}

setInterval(() => state && paintStatus(), 1000)
refresh()
setInterval(refresh, 60_000)
