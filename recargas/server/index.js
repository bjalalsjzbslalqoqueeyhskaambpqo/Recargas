const express = require('express')
const http = require('http')
const bcrypt = require('bcrypt')
const jwt = require('jsonwebtoken')
const fs = require('fs')
const path = require('path')
const rateLimit = require('express-rate-limit')
const helmet = require('helmet')
require('dotenv').config({ path: path.join(__dirname, '..', '.env') })
const db = require('./db')

const app = express()
app.set('trust proxy', 1)

const PORT = Number(process.env.PORT || 3000)
const HOST = process.env.BIND_HOST || '0.0.0.0'
const SECRET = process.env.SECRET
const APP_ADMIN_KEY = process.env.APP_ADMIN_KEY
const APP_CLIENT_KEY = process.env.APP_CLIENT_KEY || APP_ADMIN_KEY

if (!SECRET || SECRET.length < 32) {
  throw new Error('Debes definir SECRET con al menos 32 caracteres en variables de entorno.')
}
if (!APP_ADMIN_KEY || APP_ADMIN_KEY.length < 24) {
  throw new Error('Debes definir APP_ADMIN_KEY con al menos 24 caracteres en variables de entorno.')
}
if (!APP_CLIENT_KEY || APP_CLIENT_KEY.length < 24) {
  throw new Error('Debes definir APP_CLIENT_KEY con al menos 24 caracteres en variables de entorno.')
}

app.disable('x-powered-by')
app.use(helmet())
app.use(express.json({ limit: '20kb' }))
app.use('/client', express.static(path.join(__dirname, '..', 'client-app')))

const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 10,
  message: { error: 'Demasiados intentos de login.' }
})

function requireAdminAppKey(req, res, next) {
  const appKey = req.headers['x-app-key']
  if (!appKey || appKey !== APP_ADMIN_KEY) return res.status(401).json({ error: 'App key inválida.' })
  next()
}

function requireClientAppKey(req, res, next) {
  const appKey = req.headers['x-app-key']
  if (!appKey || appKey !== APP_CLIENT_KEY) return res.status(401).json({ error: 'App key inválida.' })
  next()
}

function authAdmin(req, res, next) {
  const token = req.headers.authorization?.split(' ')[1]
  if (!token) return res.status(401).json({ error: 'Sin token.' })
  try {
    const data = jwt.verify(token, SECRET)
    if (data.rol !== 'admin') return res.status(403).json({ error: 'No autorizado.' })
    req.admin = data
    next()
  } catch {
    return res.status(401).json({ error: 'Token inválido.' })
  }
}

function authUser(req, res, next) {
  const token = req.headers.authorization?.split(' ')[1]
  if (!token) return res.status(401).json({ error: 'Sin token.' })
  try {
    const data = jwt.verify(token, SECRET)
    if (data.rol !== 'usuario') return res.status(403).json({ error: 'No autorizado.' })
    req.userAuth = data
    next()
  } catch {
    return res.status(401).json({ error: 'Token inválido.' })
  }
}

function validateUsername(value) {
  return /^[a-zA-Z0-9_.-]{4,32}$/.test(value)
}

function validatePassword(value) {
  if (typeof value !== 'string' || value.length < 8 || value.length > 72) return false
  return /[A-Za-z]/.test(value) && /\d/.test(value)
}

function loadBots() {
  const baseDir = path.join(__dirname, 'bots')
  if (!fs.existsSync(baseDir)) return { services: {}, errors: ['No existe directorio de bots.'] }
  const services = {}
  const errors = []
  for (const entry of fs.readdirSync(baseDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue
    const botPath = path.join(baseDir, entry.name, 'bot.js')
    if (!fs.existsSync(botPath)) continue
    try {
      const bot = require(botPath)
      if (typeof bot?.procesar === 'function') {
        services[entry.name] = bot
      } else if (typeof bot?.recargar === 'function') {
        services[entry.name] = {
          ...bot,
          procesar: async ({ referencia, monto, tarjetas }) => bot.recargar(referencia, monto, tarjetas)
        }
      }
    } catch (err) {
      const msg = `No se pudo cargar bot ${entry.name}: ${err.message}`
      errors.push(msg)
      console.warn(msg)
    }
  }
  return { services, errors }
}

let botLoadResult = loadBots()
let bots = botLoadResult.services

function refreshBots() {
  botLoadResult = loadBots()
  bots = botLoadResult.services
}

const CATALOGO_SERVICIOS = [
  { id: 'movistar', nombre: 'Movistar', montos: [2000, 4000, 5000, 6000, 7000, 8000, 10000, 15000, 20000] },
  { id: 'personal', nombre: 'Personal', montos: [4000, 5000, 6000, 7000, 8000, 9000, 10000, 12000, 15000, 30000] }
]

function getCardMetrics(cardId) {
  return db.prepare('SELECT * FROM tarjeta_metricas WHERE tarjeta_id = ?').all(cardId)
}

function registerCardResult(cardId, adminId, servicio, ok, detalle) {
  const row = db.prepare('SELECT * FROM tarjeta_metricas WHERE tarjeta_id = ? AND servicio = ?').get(cardId, servicio)
  const nextConsecutiveFails = ok ? 0 : (row ? Number(row.fallos_consecutivos) + 1 : 1)
  if (!row) {
    db.prepare(
      `INSERT INTO tarjeta_metricas (tarjeta_id, servicio, intentos, exitos, fallos, fallos_consecutivos)
       VALUES (?, ?, 1, ?, ?, ?)`
    ).run(cardId, servicio, ok ? 1 : 0, ok ? 0 : 1, nextConsecutiveFails)
  } else {
    db.prepare(
      `UPDATE tarjeta_metricas
       SET intentos = intentos + 1,
           exitos = exitos + ?,
           fallos = fallos + ?,
           fallos_consecutivos = ?,
           actualizado = datetime('now')
       WHERE id = ?`
    ).run(ok ? 1 : 0, ok ? 0 : 1, nextConsecutiveFails, row.id)
  }
  db.prepare(
    `UPDATE tarjetas
     SET ultimo_uso = datetime('now'),
         ultimo_estado = ?,
         ultimo_servicio = ?
     WHERE id = ?`
  ).run(ok ? 'ok' : 'fallo', servicio, cardId)
  if (detalle) {
    db.prepare(
      `INSERT INTO historial (admin_id, servicio, estado, mensaje) VALUES (?, ?, ?, ?)`
    ).run(adminId, servicio, ok ? 'ok_tarjeta' : 'fallo_tarjeta', String(detalle).slice(0, 280))
  }
  if (!ok && nextConsecutiveFails === 5) {
    const card = db.prepare('SELECT alias, numero FROM tarjetas WHERE id = ? AND admin_id = ?').get(cardId, adminId)
    if (card) {
      const masked = String(card.numero).slice(-4)
      const msg = `Tarjeta ${card.alias || ''} ****${masked} quedó bloqueada para ${servicio} por 5 fallos consecutivos.`.trim()
      db.prepare('INSERT INTO notificaciones_admin (admin_id, tipo, mensaje) VALUES (?, ?, ?)').run(adminId, 'tarjeta_bloqueada_servicio', msg)
    }
  }
}

app.get('/api/status', (_req, res) => {
  res.json({
    ok: true,
    servicio: 'recargas-admin-api',
    bots: {
      cargados: Object.keys(bots),
      total: Object.keys(bots).length,
      errores: botLoadResult.errors
    }
  })
})

app.use('/api/admin', requireAdminAppKey)
app.use('/api/client', requireClientAppKey)

app.post('/api/admin/login', loginLimiter, async (req, res) => {
  const { usuario, password } = req.body || {}
  if (!validateUsername(usuario) || typeof password !== 'string') {
    return res.status(400).json({ error: 'Credenciales inválidas.' })
  }
  const admin = db.prepare('SELECT * FROM admins WHERE usuario = ? AND activo = 1').get(usuario)
  if (!admin) return res.status(401).json({ error: 'Credenciales inválidas.' })
  const ok = await bcrypt.compare(password, admin.password)
  if (!ok) return res.status(401).json({ error: 'Credenciales inválidas.' })
  const token = jwt.sign({ id: admin.id, usuario: admin.usuario, rol: 'admin' }, SECRET, { expiresIn: '12h' })
  res.json({ token })
})

app.post('/api/client/login', loginLimiter, async (req, res) => {
  const { usuario, password } = req.body || {}
  if (!validateUsername(usuario) || typeof password !== 'string') {
    return res.status(400).json({ error: 'Credenciales inválidas.' })
  }
  const user = db.prepare('SELECT id, admin_id, usuario, password, activo FROM usuarios WHERE usuario = ?').get(usuario)
  if (!user || Number(user.activo) !== 1) return res.status(401).json({ error: 'Credenciales inválidas.' })
  const ok = await bcrypt.compare(password, user.password)
  if (!ok) return res.status(401).json({ error: 'Credenciales inválidas.' })
  const token = jwt.sign({ id: user.id, admin_id: user.admin_id, usuario: user.usuario, rol: 'usuario' }, SECRET, { expiresIn: '12h' })
  res.json({ token })
})

app.get('/api/client/me', authUser, (req, res) => {
  const user = db.prepare('SELECT id, usuario, saldo, activo, creado FROM usuarios WHERE id = ?').get(req.userAuth.id)
  if (!user || Number(user.activo) !== 1) return res.status(404).json({ error: 'Usuario no encontrado.' })
  res.json(user)
})

app.get('/api/client/servicios', authUser, (req, res) => {
  if (Object.keys(bots).length === 0) refreshBots()
  const catalogo = CATALOGO_SERVICIOS.map((item) => ({
    ...item,
    disponible: Boolean(bots[item.id])
  }))
  res.json(catalogo)
})

app.get('/api/client/historial', authUser, (req, res) => {
  const rows = db.prepare(
    `SELECT servicio, referencia, monto, estado, mensaje, fecha
     FROM historial
     WHERE usuario_id = ? AND admin_id = ?
     ORDER BY id DESC LIMIT 100`
  ).all(req.userAuth.id, req.userAuth.admin_id)
  res.json(rows)
})

app.post('/api/client/recargar', authUser, async (req, res) => {
  const servicio = String(req.body?.servicio || '').trim().toLowerCase()
  const monto = Number(req.body?.monto)
  const referencia = String(req.body?.referencia || '').replace(/\D/g, '')

  const bot = bots[servicio]
  const servicioInfo = CATALOGO_SERVICIOS.find((item) => item.id === servicio)
  if (!bot || !servicioInfo) return res.status(400).json({ error: 'Servicio no disponible.' })
  if (!Number.isFinite(monto) || !servicioInfo.montos.includes(monto)) {
    return res.status(400).json({ error: 'Monto inválido para el servicio seleccionado.' })
  }
  if (!/^\d{10}$/.test(referencia)) {
    return res.status(400).json({ error: 'Número inválido. Debe tener 10 dígitos.' })
  }

  const user = db.prepare('SELECT id, saldo, activo FROM usuarios WHERE id = ? AND admin_id = ?').get(req.userAuth.id, req.userAuth.admin_id)
  if (!user || Number(user.activo) !== 1) return res.status(404).json({ error: 'Usuario no encontrado.' })

  try {
    db.prepare('INSERT INTO recarga_locks (usuario_id) VALUES (?)').run(req.userAuth.id)
  } catch {
    return res.status(409).json({ error: 'Ya tienes una recarga en proceso. Espera a que termine.' })
  }

  try {
    const saldoActual = Number(
      db.prepare('SELECT saldo FROM usuarios WHERE id = ? AND admin_id = ?').get(req.userAuth.id, req.userAuth.admin_id)?.saldo || 0
    )
    if (saldoActual < monto) return res.status(400).json({ error: 'Saldo insuficiente.' })

    const tarjetas = db.prepare(
      `SELECT t.id, t.numero, t.mes, t.anio, t.cvv
       FROM tarjetas t
       LEFT JOIN tarjeta_metricas m ON m.tarjeta_id = t.id AND m.servicio = ?
       WHERE t.admin_id = ? AND t.activa = 1 AND t.ignorada = 0
         AND COALESCE(m.fallos_consecutivos, 0) < 5
       ORDER BY t.id ASC`
    ).all(servicio, req.userAuth.admin_id)
    if (tarjetas.length === 0) return res.status(400).json({ error: 'No hay tarjetas activas disponibles.' })

    let resultado
    try {
      resultado = await bot.procesar({ referencia, monto, tarjetas })
    } catch {
      resultado = { ok: false, mensaje: 'No se pudo completar la recarga. Comuníquese con el administrador.' }
    }

    const ok = Boolean(resultado?.ok)
    const mensaje = ok
      ? String(resultado?.mensaje || 'Recarga exitosa').slice(0, 280)
      : 'No se pudo completar la recarga. Comuníquese con el administrador.'

    const txResult = db.transaction(() => {
      const current = db.prepare('SELECT saldo FROM usuarios WHERE id = ? AND admin_id = ?').get(req.userAuth.id, req.userAuth.admin_id)
      if (!current) throw new Error('Usuario no encontrado.')
      if (ok && Number(current.saldo) < monto) throw new Error('Saldo insuficiente al confirmar la recarga.')
      if (ok) db.prepare('UPDATE usuarios SET saldo = saldo - ? WHERE id = ?').run(monto, req.userAuth.id)
      db.prepare(
        `INSERT INTO historial (usuario_id, admin_id, servicio, referencia, monto, estado, mensaje)
         VALUES (?, ?, ?, ?, ?, ?, ?)`
      ).run(req.userAuth.id, req.userAuth.admin_id, servicio, referencia, monto, ok ? 'ok' : 'fallo', mensaje)
      return { ok, mensaje }
    })()

    if (Number.isInteger(resultado?.tarjeta_idx)) {
      const card = tarjetas[resultado.tarjeta_idx]
      if (card) registerCardResult(card.id, req.userAuth.admin_id, servicio, ok, txResult.mensaje)
    }

    return res.status(txResult.ok ? 200 : 502).json(txResult)
  } finally {
    db.prepare('DELETE FROM recarga_locks WHERE usuario_id = ?').run(req.userAuth.id)
  }
})

app.get('/api/admin/perfil', authAdmin, (req, res) => {
  const admin = db.prepare('SELECT id, usuario, activo, creado FROM admins WHERE id = ?').get(req.admin.id)
  res.json(admin)
})

app.get('/api/admin/me', authAdmin, (req, res) => {
  const admin = db.prepare('SELECT id, usuario, activo, creado FROM admins WHERE id = ?').get(req.admin.id)
  res.json(admin)
})

app.patch('/api/admin/perfil', authAdmin, async (req, res) => {
  const { usuario, password } = req.body || {}
  if (usuario !== undefined && !validateUsername(usuario)) return res.status(400).json({ error: 'Usuario inválido.' })
  if (password !== undefined && !validatePassword(password)) return res.status(400).json({ error: 'Password inválida.' })
  try {
    if (usuario !== undefined) db.prepare('UPDATE admins SET usuario = ? WHERE id = ?').run(usuario, req.admin.id)
    if (password !== undefined) {
      const hash = await bcrypt.hash(password, 12)
      db.prepare('UPDATE admins SET password = ? WHERE id = ?').run(hash, req.admin.id)
    }
    const admin = db.prepare('SELECT id, usuario, activo, creado FROM admins WHERE id = ?').get(req.admin.id)
    res.json({ ok: true, admin })
  } catch {
    res.status(400).json({ error: 'No se pudo actualizar perfil admin.' })
  }
})

app.patch('/api/admin/me', authAdmin, async (req, res) => {
  const { usuario, password } = req.body || {}
  if (usuario !== undefined && !validateUsername(usuario)) return res.status(400).json({ error: 'Usuario inválido.' })
  if (password !== undefined && !validatePassword(password)) return res.status(400).json({ error: 'Password inválida.' })
  try {
    if (usuario !== undefined) db.prepare('UPDATE admins SET usuario = ? WHERE id = ?').run(usuario, req.admin.id)
    if (password !== undefined) {
      const hash = await bcrypt.hash(password, 12)
      db.prepare('UPDATE admins SET password = ? WHERE id = ?').run(hash, req.admin.id)
    }
    const admin = db.prepare('SELECT id, usuario, activo, creado FROM admins WHERE id = ?').get(req.admin.id)
    res.json({ ok: true, admin })
  } catch {
    res.status(400).json({ error: 'No se pudo actualizar perfil admin.' })
  }
})

app.get('/api/admin/usuarios', authAdmin, (req, res) => {
  const rows = db.prepare('SELECT id, usuario, saldo, activo, creado FROM usuarios WHERE admin_id = ? ORDER BY id DESC').all(req.admin.id)
  res.json(rows)
})

app.post('/api/admin/usuarios', authAdmin, async (req, res) => {
  const { usuario, password, saldo } = req.body || {}
  if (!validateUsername(usuario) || !validatePassword(password)) {
    return res.status(400).json({ error: 'Usuario o contraseña inválidos.' })
  }
  const initialSaldo = Number(saldo || 0)
  if (!Number.isFinite(initialSaldo) || initialSaldo < 0) return res.status(400).json({ error: 'Saldo inicial inválido.' })
  try {
    const hash = await bcrypt.hash(password, 12)
    const result = db.prepare('INSERT INTO usuarios (admin_id, usuario, password, saldo) VALUES (?, ?, ?, ?)').run(req.admin.id, usuario, hash, initialSaldo)
    res.json({ id: Number(result.lastInsertRowid), usuario, saldo: initialSaldo })
  } catch {
    res.status(400).json({ error: 'No se pudo crear usuario.' })
  }
})

app.patch('/api/admin/usuarios/:id', authAdmin, async (req, res) => {
  const userId = Number(req.params.id)
  const { usuario, password, saldo, activo } = req.body || {}
  if (!Number.isInteger(userId) || userId <= 0) return res.status(400).json({ error: 'Usuario inválido.' })
  if (usuario !== undefined && !validateUsername(usuario)) return res.status(400).json({ error: 'Usuario inválido.' })
  if (password !== undefined && !validatePassword(password)) return res.status(400).json({ error: 'Password inválida.' })
  if (saldo !== undefined && (!Number.isFinite(Number(saldo)) || Number(saldo) < 0)) return res.status(400).json({ error: 'Saldo inválido.' })
  if (activo !== undefined && ![0, 1, true, false].includes(activo)) return res.status(400).json({ error: 'Activo inválido.' })
  const existing = db.prepare('SELECT id FROM usuarios WHERE id = ? AND admin_id = ?').get(userId, req.admin.id)
  if (!existing) return res.status(404).json({ error: 'Usuario no encontrado.' })
  try {
    if (usuario  !== undefined) db.prepare('UPDATE usuarios SET usuario = ? WHERE id = ?').run(usuario, userId)
    if (password !== undefined) { const hash = await bcrypt.hash(password, 12); db.prepare('UPDATE usuarios SET password = ? WHERE id = ?').run(hash, userId) }
    if (saldo    !== undefined) db.prepare('UPDATE usuarios SET saldo = ? WHERE id = ?').run(Number(saldo), userId)
    if (activo   !== undefined) db.prepare('UPDATE usuarios SET activo = ? WHERE id = ?').run(Number(activo ? 1 : 0), userId)
    const updated = db.prepare('SELECT id, usuario, saldo, activo, creado FROM usuarios WHERE id = ? AND admin_id = ?').get(userId, req.admin.id)
    return res.json({ ok: true, usuario: updated })
  } catch {
    return res.status(400).json({ error: 'No se pudo actualizar usuario.' })
  }
})

app.delete('/api/admin/usuarios/:id', authAdmin, (req, res) => {
  const userId = Number(req.params.id)
  const user = db.prepare('SELECT id FROM usuarios WHERE id = ? AND admin_id = ?').get(userId, req.admin.id)
  if (!user) return res.status(404).json({ error: 'Usuario no encontrado.' })
  db.prepare('DELETE FROM usuarios WHERE id = ?').run(userId)
  res.json({ ok: true })
})

app.patch('/api/admin/usuarios/:id/saldo', authAdmin, (req, res) => {
  const userId = Number(req.params.id)
  const delta = Number(req.body?.delta)
  if (!Number.isInteger(userId) || userId <= 0) return res.status(400).json({ error: 'Usuario inválido.' })
  if (!Number.isFinite(delta) || delta === 0) return res.status(400).json({ error: 'Delta inválido.' })
  const user = db.prepare('SELECT id FROM usuarios WHERE id = ? AND admin_id = ?').get(userId, req.admin.id)
  if (!user) return res.status(404).json({ error: 'Usuario no encontrado.' })
  const newSaldo = db.transaction(() => {
    db.prepare('UPDATE usuarios SET saldo = saldo + ? WHERE id = ?').run(delta, userId)
    return db.prepare('SELECT saldo FROM usuarios WHERE id = ?').get(userId)?.saldo ?? 0
  })()
  res.json({ ok: true, saldo: Number(newSaldo) })
})

app.get('/api/admin/historial', authAdmin, (req, res) => {
  const rows = db.prepare(
    `SELECT h.id, h.servicio, h.referencia, h.monto, h.estado, h.mensaje, h.fecha, u.usuario
     FROM historial h
     LEFT JOIN usuarios u ON u.id = h.usuario_id
     WHERE h.admin_id = ?
     ORDER BY h.id DESC LIMIT 300`
  ).all(req.admin.id)
  res.json(rows)
})

app.get('/api/admin/tarjetas', authAdmin, (req, res) => {
  const cards = db.prepare('SELECT id, alias, numero, mes, anio, activa, ignorada, motivo_ignorada, creada, ultimo_uso, ultimo_estado, ultimo_servicio FROM tarjetas WHERE admin_id = ? ORDER BY id DESC').all(req.admin.id)
  res.json(cards.map(card => ({
    ...card,
    numero: `**** **** **** ${String(card.numero).slice(-4)}`,
    metricas: getCardMetrics(card.id)
  })))
})

app.post('/api/admin/tarjetas', authAdmin, (req, res) => {
  const { alias, numero, mes, anio, cvv } = req.body || {}
  if (!numero || !mes || !anio || !cvv) return res.status(400).json({ error: 'Faltan datos.' })
  const result = db.prepare(
    'INSERT INTO tarjetas (admin_id, alias, numero, mes, anio, cvv) VALUES (?, ?, ?, ?, ?, ?)'
  ).run(req.admin.id, alias || '', String(numero).trim(), String(mes).trim(), String(anio).trim(), String(cvv).trim())
  res.json({ id: Number(result.lastInsertRowid) })
})

app.patch('/api/admin/tarjetas/:id/activa', authAdmin, (req, res) => {
  const cardId = Number(req.params.id)
  const card = db.prepare('SELECT id FROM tarjetas WHERE id = ? AND admin_id = ?').get(cardId, req.admin.id)
  if (!card) return res.status(404).json({ error: 'Tarjeta no encontrada.' })
  db.prepare('UPDATE tarjetas SET activa = ? WHERE id = ?').run(Number(req.body?.activa) ? 1 : 0, cardId)
  res.json({ ok: true })
})

app.delete('/api/admin/tarjetas/:id', authAdmin, (req, res) => {
  const cardId = Number(req.params.id)
  const card = db.prepare('SELECT id FROM tarjetas WHERE id = ? AND admin_id = ?').get(cardId, req.admin.id)
  if (!card) return res.status(404).json({ error: 'Tarjeta no encontrada.' })
  db.prepare('DELETE FROM tarjeta_metricas WHERE tarjeta_id = ?').run(cardId)
  db.prepare('DELETE FROM tarjetas WHERE id = ?').run(cardId)
  res.json({ ok: true })
})

app.post('/api/admin/tarjetas/:id/resultado', authAdmin, (req, res) => {
  const cardId = Number(req.params.id)
  const { servicio, ok, detalle } = req.body || {}
  if (!servicio || typeof ok !== 'boolean') return res.status(400).json({ error: 'servicio y ok son requeridos.' })
  const card = db.prepare('SELECT id, ignorada FROM tarjetas WHERE id = ? AND admin_id = ?').get(cardId, req.admin.id)
  if (!card) return res.status(404).json({ error: 'Tarjeta no encontrada.' })
  if (Number(card.ignorada) === 1) return res.status(400).json({ error: 'Tarjeta ya ignorada.' })
  registerCardResult(cardId, req.admin.id, servicio, ok, detalle)
  const updated = db.prepare('SELECT id, activa, ignorada, motivo_ignorada FROM tarjetas WHERE id = ?').get(cardId)
  res.json({ ok: true, tarjeta: updated })
})

app.get('/api/admin/notificaciones', authAdmin, (req, res) => {
  const rows = db.prepare('SELECT id, tipo, mensaje, leida, creada FROM notificaciones_admin WHERE admin_id = ? ORDER BY id DESC LIMIT 100').all(req.admin.id)
  res.json(rows)
})

app.patch('/api/admin/notificaciones/:id/leida', authAdmin, (req, res) => {
  db.prepare('UPDATE notificaciones_admin SET leida = 1 WHERE id = ? AND admin_id = ?').run(Number(req.params.id), req.admin.id)
  res.json({ ok: true })
})

app.use((err, _req, res, _next) => {
  console.error(err)
  res.status(500).json({ error: 'Error interno del servidor.' })
})

http.createServer(app).listen(PORT, HOST, () => {
  console.log(`API admin escuchando en http://${HOST}:${PORT}`)
  console.log(`Bots cargados: ${Object.keys(bots).join(', ') || 'ninguno'}`)
  if (botLoadResult.errors.length > 0) {
    console.warn('Errores al cargar bots:', botLoadResult.errors)
  }
})
