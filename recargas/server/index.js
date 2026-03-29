const express = require('express')
const http = require('http')
const https = require('https')
const bcrypt = require('bcrypt')
const jwt = require('jsonwebtoken')
const path = require('path')
const fs = require('fs')
const helmet = require('helmet')
const rateLimit = require('express-rate-limit')
require('dotenv').config({ path: path.join(__dirname, '../.env') })
const db = require('./db')

const app = express()
app.set('trust proxy', 1)
const PORT = Number(process.env.PORT || 3000)
const HOST = process.env.BIND_HOST || '127.0.0.1'
const SECRET = process.env.SECRET

if (!SECRET || SECRET.length < 32) {
  throw new Error('Debes definir SECRET con al menos 32 caracteres en variables de entorno.')
}

const userInProgress = new Set()
const BOTS_DIR = path.join(__dirname, 'bots')

app.disable('x-powered-by')
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'", "'unsafe-inline'"],
      styleSrc: ["'self'", "'unsafe-inline'"],
      imgSrc: ["'self'", 'data:']
    }
  }
}))
app.use(express.json({ limit: '20kb' }))
app.use(express.static(path.join(__dirname, '../public'), { index: false }))

const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 10,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Demasiados intentos. Intenta más tarde.' }
})

const recargaLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 8,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Límite de solicitudes excedido.' }
})

function tokenFromReq(req) {
  return req.headers.authorization?.split(' ')[1]
}

function authRole(role) {
  return (req, res, next) => {
    const token = tokenFromReq(req)
    if (!token) return res.status(401).json({ error: 'Sin token.' })

    try {
      const data = jwt.verify(token, SECRET)
      if (data.rol !== role) return res.status(403).json({ error: 'No autorizado.' })
      req.auth = data
      next()
    } catch {
      return res.status(401).json({ error: 'Token inválido.' })
    }
  }
}

function safeServiceId(id) {
  return /^[a-z0-9-_]{2,40}$/i.test(id)
}

function prettifyName(folder) {
  return folder
    .replace(/[-_]+/g, ' ')
    .replace(/\b\w/g, letter => letter.toUpperCase())
}

function loadServiceFromFolder(folderName) {
  if (!safeServiceId(folderName)) return null

  const serviceDir = path.join(BOTS_DIR, folderName)
  const botPath = path.join(serviceDir, 'bot.js')
  const uiPath = path.join(serviceDir, 'ui.html')

  if (!fs.existsSync(botPath) || !fs.existsSync(uiPath)) return null

  delete require.cache[require.resolve(botPath)]
  const botModule = require(botPath)

  if (typeof botModule.procesar !== 'function') return null
  if (botModule.disponible === false) return null

  return {
    id: folderName,
    nombre: String(botModule.nombre || prettifyName(folderName)),
    montos: Array.isArray(botModule.montos) ? botModule.montos.filter(n => Number.isFinite(Number(n))).map(Number) : [],
    validarReferencia: typeof botModule.validarReferencia === 'function' ? botModule.validarReferencia : null,
    bot: botModule,
    uiPath
  }
}

function discoverServices() {
  if (!fs.existsSync(BOTS_DIR)) return []

  return fs.readdirSync(BOTS_DIR, { withFileTypes: true })
    .filter(dirent => dirent.isDirectory())
    .map(dirent => loadServiceFromFolder(dirent.name))
    .filter(Boolean)
}

function getServiceById(id) {
  return discoverServices().find(service => service.id === id) || null
}

function validateUsername(value) {
  return /^[a-zA-Z0-9_.-]{4,32}$/.test(value)
}

function validatePassword(value) {
  if (typeof value !== 'string' || value.length < 8 || value.length > 72) return false
  const hasLetter = /[A-Za-z]/.test(value)
  const hasNumber = /\d/.test(value)
  return hasLetter && hasNumber
}

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
  return res.json({ token })
})

app.post('/api/login', loginLimiter, async (req, res) => {
  const { usuario, password } = req.body || {}
  if (!validateUsername(usuario) || typeof password !== 'string') {
    return res.status(400).json({ error: 'Credenciales inválidas.' })
  }

  const user = db.prepare('SELECT * FROM usuarios WHERE usuario = ? AND activo = 1').get(usuario)
  if (!user) return res.status(401).json({ error: 'Credenciales inválidas.' })

  const ok = await bcrypt.compare(password, user.password)
  if (!ok) return res.status(401).json({ error: 'Credenciales inválidas.' })

  const token = jwt.sign({ id: user.id, admin_id: user.admin_id, usuario: user.usuario, rol: 'usuario' }, SECRET, { expiresIn: '12h' })
  return res.json({ token, saldo: Number(user.saldo) })
})

app.get('/api/servicios', authRole('usuario'), (_req, res) => {
  const catalogo = discoverServices().map(({ id, nombre, montos }) => ({ id, nombre, montos }))
  return res.json(catalogo)
})

app.get('/api/servicios/:id/ui', authRole('usuario'), (req, res) => {
  const service = getServiceById(req.params.id)
  if (!service) return res.status(404).json({ error: 'Servicio no encontrado.' })

  const fragment = fs.readFileSync(service.uiPath, 'utf8')
  return res.type('html').send(fragment)
})

const registrarYDescontar = db.transaction(({ usuarioId, adminId, servicio, referencia, monto }) => {
  const user = db.prepare('SELECT saldo FROM usuarios WHERE id = ? AND activo = 1').get(usuarioId)
  if (!user) return { ok: false, status: 404, error: 'Usuario no encontrado o inactivo.' }

  if (Number(user.saldo) < monto) return { ok: false, status: 400, error: 'Saldo insuficiente.' }

  db.prepare('UPDATE usuarios SET saldo = saldo - ? WHERE id = ?').run(monto, usuarioId)
  const result = db.prepare(
    `INSERT INTO historial (usuario_id, admin_id, servicio, referencia, monto, estado, mensaje)
     VALUES (?, ?, ?, ?, ?, 'procesando', 'En proceso')`
  ).run(usuarioId, adminId, servicio, referencia, monto)

  return { ok: true, historialId: Number(result.lastInsertRowid) }
})

const finalizarRecarga = db.transaction(({ historialId, usuarioId, monto, success, mensaje }) => {
  const estado = success ? 'exitoso' : 'fallido'
  db.prepare('UPDATE historial SET estado = ?, mensaje = ? WHERE id = ?').run(estado, mensaje, historialId)

  if (!success) {
    db.prepare('UPDATE usuarios SET saldo = saldo + ? WHERE id = ?').run(monto, usuarioId)
  }
})

app.post('/api/recargar', authRole('usuario'), recargaLimiter, async (req, res) => {
  const { servicio, referencia, monto } = req.body || {}
  const service = getServiceById(servicio)

  if (!service) return res.status(400).json({ error: 'Servicio inválido.' })
  if (typeof referencia !== 'string' || referencia.trim().length < 3 || referencia.trim().length > 120) {
    return res.status(400).json({ error: 'Referencia inválida.' })
  }

  const montoNum = Number(monto)
  if (!Number.isFinite(montoNum) || montoNum <= 0 || montoNum > 1000000) {
    return res.status(400).json({ error: 'Monto inválido.' })
  }

  if (service.montos.length && !service.montos.includes(montoNum)) {
    return res.status(400).json({ error: 'Monto no permitido para el servicio.' })
  }

  if (service.validarReferencia && !service.validarReferencia(referencia.trim())) {
    return res.status(400).json({ error: 'Referencia inválida para el servicio.' })
  }

  if (userInProgress.has(req.auth.id)) {
    return res.status(409).json({ error: 'Ya tienes una recarga en procesamiento.' })
  }

  userInProgress.add(req.auth.id)

  try {
    const tx = registrarYDescontar({
      usuarioId: req.auth.id,
      adminId: req.auth.admin_id,
      servicio: service.id,
      referencia: referencia.trim(),
      monto: montoNum
    })

    if (!tx.ok) return res.status(tx.status).json({ error: tx.error })

    const botResult = await service.bot.procesar({ referencia: referencia.trim(), monto: montoNum, usuario: req.auth.usuario })
    const success = Boolean(botResult?.ok)
    const mensaje = String(botResult?.mensaje || (success ? 'Recarga procesada.' : 'Recarga rechazada.'))

    finalizarRecarga({
      historialId: tx.historialId,
      usuarioId: req.auth.id,
      monto: montoNum,
      success,
      mensaje
    })

    const saldo = db.prepare('SELECT saldo FROM usuarios WHERE id = ?').get(req.auth.id)?.saldo ?? 0
    return res.json({ ok: success, estado: success ? 'exitoso' : 'fallido', mensaje, saldo: Number(saldo) })
  } catch (error) {
    return res.status(500).json({ error: 'Error interno procesando recarga.' })
  } finally {
    userInProgress.delete(req.auth.id)
  }
})

app.get('/api/saldo', authRole('usuario'), (req, res) => {
  const row = db.prepare('SELECT saldo FROM usuarios WHERE id = ?').get(req.auth.id)
  return res.json({ saldo: Number(row?.saldo || 0) })
})

app.get('/api/historial', authRole('usuario'), (req, res) => {
  const rows = db.prepare('SELECT id, servicio, referencia, monto, estado, mensaje, fecha FROM historial WHERE usuario_id = ? ORDER BY id DESC LIMIT 100').all(req.auth.id)
  return res.json(rows)
})

app.get('/api/admin/usuarios', authRole('admin'), (req, res) => {
  const rows = db.prepare('SELECT id, usuario, saldo, activo, creado FROM usuarios WHERE admin_id = ? ORDER BY id DESC').all(req.auth.id)
  return res.json(rows)
})

app.post('/api/admin/usuarios', authRole('admin'), async (req, res) => {
  const { usuario, password, saldo } = req.body || {}

  if (!validateUsername(usuario) || !validatePassword(password)) {
    return res.status(400).json({ error: 'Usuario o contraseña inválidos.' })
  }

  const initialSaldo = Number(saldo || 0)
  if (!Number.isFinite(initialSaldo) || initialSaldo < 0 || initialSaldo > 10000000) {
    return res.status(400).json({ error: 'Saldo inicial inválido.' })
  }

  try {
    const hash = await bcrypt.hash(password, 12)
    const result = db.prepare('INSERT INTO usuarios (admin_id, usuario, password, saldo) VALUES (?, ?, ?, ?)').run(req.auth.id, usuario, hash, initialSaldo)
    return res.json({ id: Number(result.lastInsertRowid), usuario, saldo: initialSaldo })
  } catch {
    return res.status(400).json({ error: 'No se pudo crear el usuario.' })
  }
})

app.put('/api/admin/usuarios/:id/saldo', authRole('admin'), (req, res) => {
  const userId = Number(req.params.id)
  const monto = Number(req.body?.monto)

  if (!Number.isInteger(userId) || userId <= 0) return res.status(400).json({ error: 'Usuario inválido.' })
  if (!Number.isFinite(monto) || monto === 0 || Math.abs(monto) > 1000000) return res.status(400).json({ error: 'Monto inválido.' })

  const user = db.prepare('SELECT id FROM usuarios WHERE id = ? AND admin_id = ?').get(userId, req.auth.id)
  if (!user) return res.status(404).json({ error: 'Usuario no encontrado.' })

  const balance = db.transaction(() => {
    db.prepare('UPDATE usuarios SET saldo = saldo + ? WHERE id = ?').run(monto, userId)
    return db.prepare('SELECT saldo FROM usuarios WHERE id = ?').get(userId)?.saldo ?? 0
  })()

  return res.json({ ok: true, saldo: Number(balance) })
})

app.get('/api/admin/historial', authRole('admin'), (req, res) => {
  const rows = db.prepare(
    `SELECT h.id, h.servicio, h.referencia, h.monto, h.estado, h.mensaje, h.fecha, u.usuario
     FROM historial h
     LEFT JOIN usuarios u ON u.id = h.usuario_id
     WHERE h.admin_id = ?
     ORDER BY h.id DESC
     LIMIT 200`
  ).all(req.auth.id)

  return res.json(rows)
})

app.get('/admin', (_req, res) => {
  return res.sendFile(path.join(__dirname, '../public/admin.html'))
})

app.get('/', (_req, res) => {
  return res.sendFile(path.join(__dirname, '../public/index.html'))
})

app.use((err, _req, res, _next) => {
  console.error(err)
  return res.status(500).json({ error: 'Error interno del servidor.' })
})

const DIRECT_TLS = process.env.DIRECT_TLS === 'true'
const SSL_KEY_PATH = process.env.SSL_KEY_PATH
const SSL_CERT_PATH = process.env.SSL_CERT_PATH

if (DIRECT_TLS && SSL_KEY_PATH && SSL_CERT_PATH && fs.existsSync(SSL_KEY_PATH) && fs.existsSync(SSL_CERT_PATH)) {
  const httpsOptions = {
    key: fs.readFileSync(SSL_KEY_PATH),
    cert: fs.readFileSync(SSL_CERT_PATH)
  }

  https.createServer(httpsOptions, app).listen(PORT, HOST, () => {
    console.log(`Servidor HTTPS listo en https://${HOST}:${PORT}`)
  })
} else {
  http.createServer(app).listen(PORT, HOST, () => {
    console.log(`Servidor HTTP listo en http://${HOST}:${PORT}`)
  })
}
