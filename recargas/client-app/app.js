const API_BASE = localStorage.getItem('api_base') || location.origin
const APP_KEY = localStorage.getItem('app_key') || 'dev-change-me'
let token = localStorage.getItem('client_token') || ''
let servicios = []

const el = (id) => document.getElementById(id)

async function api(path, method = 'GET', body) {
  const res = await fetch(`${API_BASE}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      'X-App-Key': APP_KEY,
      ...(token ? { Authorization: `Bearer ${token}` } : {})
    },
    body: body ? JSON.stringify(body) : undefined
  })
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`)
  return data
}

function showLoggedIn(show) {
  el('loginCard').classList.toggle('hidden', show)
  el('appCard').classList.toggle('hidden', !show)
}

async function checkServer() {
  try {
    const r = await fetch(`${API_BASE}/api/status`)
    el('serverStatus').textContent = r.ok ? `Servidor: conectado (${API_BASE})` : 'Servidor: error'
  } catch (e) {
    el('serverStatus').textContent = `Servidor: sin conexión (${e.message})`
  }
}

async function loadMeAndServicios() {
  const me = await api('/api/client/me')
  el('welcome').textContent = `Hola, ${me.usuario}`
  el('saldo').textContent = `Saldo: $${Number(me.saldo).toFixed(2)}`

  servicios = await api('/api/client/servicios')
  const servicioSel = el('servicio')
  servicioSel.innerHTML = ''
  servicios.forEach((s, i) => {
    const opt = document.createElement('option')
    opt.value = s.id
    opt.textContent = s.nombre
    servicioSel.appendChild(opt)
    if (i === 0) setMontos(s.id)
  })
}

function setMontos(servicioId) {
  const srv = servicios.find((s) => s.id === servicioId)
  const montoSel = el('monto')
  montoSel.innerHTML = ''
  ;(srv?.montos || []).forEach((m) => {
    const opt = document.createElement('option')
    opt.value = String(m)
    opt.textContent = `$${m}`
    montoSel.appendChild(opt)
  })
}

async function loadHistorial() {
  const rows = await api('/api/client/historial')
  const list = el('historial')
  list.innerHTML = ''
  rows.forEach((r) => {
    const li = document.createElement('li')
    li.textContent = `${r.fecha} · ${r.servicio} · ${r.estado} · ${r.mensaje || ''}`
    list.appendChild(li)
  })
}

el('servicio').addEventListener('change', (e) => setMontos(e.target.value))

el('btnLogin').addEventListener('click', async () => {
  const usuario = el('inputUser').value.trim()
  const password = el('inputPass').value
  try {
    const out = await api('/api/client/login', 'POST', { usuario, password })
    token = out.token
    localStorage.setItem('client_token', token)
    el('loginMsg').textContent = 'Login OK'
    showLoggedIn(true)
    await loadMeAndServicios()
    await loadHistorial()
  } catch (e) {
    el('loginMsg').textContent = e.message
  }
})

el('btnRecargar').addEventListener('click', async () => {
  try {
    const payload = {
      servicio: el('servicio').value,
      monto: Number(el('monto').value),
      referencia: el('referencia').value.trim()
    }
    const out = await api('/api/client/recargar', 'POST', payload)
    el('result').textContent = `${out.ok ? 'OK' : 'Fallo'}: ${out.mensaje}`
    await loadMeAndServicios()
    await loadHistorial()
  } catch (e) {
    el('result').textContent = `Error: ${e.message}`
  }
})

el('btnReload').addEventListener('click', async () => {
  await loadMeAndServicios()
  await loadHistorial()
})

el('btnLogout').addEventListener('click', () => {
  token = ''
  localStorage.removeItem('client_token')
  showLoggedIn(false)
})

;(async () => {
  await checkServer()
  if (token) {
    try {
      showLoggedIn(true)
      await loadMeAndServicios()
      await loadHistorial()
    } catch {
      token = ''
      localStorage.removeItem('client_token')
      showLoggedIn(false)
    }
  } else {
    showLoggedIn(false)
  }
})()
