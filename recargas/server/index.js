const express = require('express')
const http = require('http')
const bcrypt = require('bcrypt')
const jwt = require('jsonwebtoken')
const path = require('path')
const rateLimit = require('express-rate-limit')
const helmet = require('helmet')
require('dotenv').config({ path: path.join(__dirname, '../.env') })
const db = require('./db')

const app = express()
app.set('trust proxy', 1)

const PORT = Number(process.env.PORT || 3000)
const HOST = process.env.BIND_HOST || '0.0.0.0'
const SECRET = process.env.SECRET

if (!SECRET || SECRET.length < 32) {
  throw new Error('Debes definir SECRET con al menos 32 caracteres en variables de entorno.')
}

app.disable('x-powered-by')
app.use(helmet())
app.use(express.json({ limit: '20kb' }))

const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 10,
  message: { error: 'Demasiados intentos de login.' }
})

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

function validateUsername(value) {
  return /^[a-zA-Z0-9_.-]{4,32}$/.test(value)
}

function validatePassword(value) {
  if (typeof value !== 'string' || value.length < 8 || value.length > 72) return false
  return /[A-Za-z]/.test(value) && /\d/.test(value)
}

function getCardMetrics(cardId) {
  return db.prepare('SELECT * FROM tarjeta_metricas WHERE tarjeta_id = ?').all(cardId)
}

function maybeIgnoreCard(cardId, adminId) {
  const metrics = getCardMetrics(cardId)
  const totalConsecutiveFails = metrics.reduce((acc, row) => acc + Number(row.fallos_consecutivos || 0), 0)
  const maxServiceConsecutive = metrics.reduce((acc, row) => Math.max(acc, Number(row.fallos_consecutivos || 0)), 0)
  const totalSuccess = metrics.reduce((acc, row) => acc + Number(row.exitos || 0), 0)

  let reason = ''
  if (totalConsecutiveFails >= 5) {
    reason = 'Ignorada automáticamente por 5 fallos consecutivos acumulados.'
  } else if (totalSuccess >= 1 && maxServiceConsecutive >= 4) {
    reason = 'Ignorada automáticamente: venía aprobando y luego acumuló 4 fallos consecutivos en un servicio.'
  }

  if (!reason) return

  const card = db.prepare('SELECT ignorada, alias, numero FROM tarjetas WHERE id = ? AND admin_id = ?').get(cardId, adminId)
  if (!card || Number(card.ignorada) === 1) return

  db.prepare('UPDATE tarjetas SET activa = 0, ignorada = 1, motivo_ignorada = ? WHERE id = ?').run(reason, cardId)
  const masked = String(card.numero).slice(-4)
  const msg = `${reason} Tarjeta ${card.alias || ''} ****${masked}`.trim()
  db.prepare('INSERT INTO notificaciones_admin (admin_id, tipo, mensaje) VALUES (?, ?, ?)').run(adminId, 'tarjeta_ignorada', msg)
}

app.get('/api/status', (_req, res) => {
  res.json({ ok: true, servicio: 'recargas-admin-api' })
})

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
  if (!Number.isFinite(initialSaldo) || initialSaldo < 0) {
    return res.status(400).json({ error: 'Saldo inicial inválido.' })
  }

  try {
    const hash = await bcrypt.hash(password, 12)
    const result = db.prepare('INSERT INTO usuarios (admin_id, usuario, password, saldo) VALUES (?, ?, ?, ?)').run(req.admin.id, usuario, hash, initialSaldo)
    res.json({ id: Number(result.lastInsertRowid), usuario, saldo: initialSaldo })
  } catch {
    res.status(400).json({ error: 'No se pudo crear usuario.' })
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
     ORDER BY h.id DESC
     LIMIT 300`
  ).all(req.admin.id)

  res.json(rows)
})

app.get('/api/admin/tarjetas', authAdmin, (req, res) => {
  const cards = db.prepare('SELECT id, alias, numero, mes, anio, activa, ignorada, motivo_ignorada, creada FROM tarjetas WHERE admin_id = ? ORDER BY id DESC').all(req.admin.id)
  const withMetrics = cards.map(card => ({
    ...card,
    numero: `**** **** **** ${String(card.numero).slice(-4)}`,
    metricas: getCardMetrics(card.id)
  }))
  res.json(withMetrics)
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
  const activa = Number(req.body?.activa) ? 1 : 0

  const card = db.prepare('SELECT id FROM tarjetas WHERE id = ? AND admin_id = ?').get(cardId, req.admin.id)
  if (!card) return res.status(404).json({ error: 'Tarjeta no encontrada.' })

  db.prepare('UPDATE tarjetas SET activa = ? WHERE id = ?').run(activa, cardId)
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

  if (!servicio || typeof ok !== 'boolean') {
    return res.status(400).json({ error: 'servicio y ok son requeridos.' })
  }

  const card = db.prepare('SELECT id, ignorada FROM tarjetas WHERE id = ? AND admin_id = ?').get(cardId, req.admin.id)
  if (!card) return res.status(404).json({ error: 'Tarjeta no encontrada.' })
  if (Number(card.ignorada) === 1) return res.status(400).json({ error: 'Tarjeta ya ignorada.' })

  const row = db.prepare('SELECT * FROM tarjeta_metricas WHERE tarjeta_id = ? AND servicio = ?').get(cardId, servicio)

  if (!row) {
    db.prepare(
      `INSERT INTO tarjeta_metricas (tarjeta_id, servicio, intentos, exitos, fallos, fallos_consecutivos)
       VALUES (?, ?, 1, ?, ?, ?)`
    ).run(cardId, servicio, ok ? 1 : 0, ok ? 0 : 1, ok ? 0 : 1)
  } else {
    db.prepare(
      `UPDATE tarjeta_metricas
       SET intentos = intentos + 1,
           exitos = exitos + ?,
           fallos = fallos + ?,
           fallos_consecutivos = ?,
           actualizado = datetime('now')
       WHERE id = ?`
    ).run(ok ? 1 : 0, ok ? 0 : 1, ok ? 0 : Number(row.fallos_consecutivos) + 1, row.id)
  }

  if (detalle) {
    db.prepare(
      `INSERT INTO historial (admin_id, servicio, estado, mensaje)
       VALUES (?, ?, ?, ?)`
    ).run(req.admin.id, servicio, ok ? 'ok_tarjeta' : 'fallo_tarjeta', String(detalle).slice(0, 280))
  }

  maybeIgnoreCard(cardId, req.admin.id)
  const updated = db.prepare('SELECT id, activa, ignorada, motivo_ignorada FROM tarjetas WHERE id = ?').get(cardId)
  res.json({ ok: true, tarjeta: updated })
})

app.get('/api/admin/notificaciones', authAdmin, (req, res) => {
  const rows = db.prepare('SELECT id, tipo, mensaje, leida, creada FROM notificaciones_admin WHERE admin_id = ? ORDER BY id DESC LIMIT 100').all(req.admin.id)
  res.json(rows)
})

app.patch('/api/admin/notificaciones/:id/leida', authAdmin, (req, res) => {
  const notifId = Number(req.params.id)
  db.prepare('UPDATE notificaciones_admin SET leida = 1 WHERE id = ? AND admin_id = ?').run(notifId, req.admin.id)
  res.json({ ok: true })
})

app.use((err, _req, res, _next) => {
  console.error(err)
  res.status(500).json({ error: 'Error interno del servidor.' })
})

http.createServer(app).listen(PORT, HOST, () => {
  console.log(`API admin escuchando en http://${HOST}:${PORT}`)
})
