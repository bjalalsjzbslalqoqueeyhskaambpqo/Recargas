const Database = require('better-sqlite3')
const path = require('path')
const bcrypt = require('bcrypt')

const db = new Database(path.join(__dirname, 'datos.db'))
db.pragma('journal_mode = WAL')

db.exec(`
  CREATE TABLE IF NOT EXISTS admins (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    usuario TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    activo INTEGER DEFAULT 1,
    creado TEXT DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS usuarios (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    admin_id INTEGER NOT NULL,
    usuario TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    saldo REAL DEFAULT 0,
    activo INTEGER DEFAULT 1,
    creado TEXT DEFAULT (datetime('now')),
    FOREIGN KEY(admin_id) REFERENCES admins(id)
  );

  CREATE TABLE IF NOT EXISTS historial (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    usuario_id INTEGER NOT NULL,
    admin_id INTEGER NOT NULL,
    servicio TEXT NOT NULL,
    referencia TEXT,
    monto REAL NOT NULL,
    estado TEXT NOT NULL,
    mensaje TEXT,
    fecha TEXT DEFAULT (datetime('now')),
    FOREIGN KEY(usuario_id) REFERENCES usuarios(id),
    FOREIGN KEY(admin_id) REFERENCES admins(id)
  );

  CREATE INDEX IF NOT EXISTS idx_usuarios_admin ON usuarios(admin_id);
  CREATE INDEX IF NOT EXISTS idx_historial_usuario ON historial(usuario_id);
  CREATE INDEX IF NOT EXISTS idx_historial_admin ON historial(admin_id);
`)

const bootstrapUser = process.env.BOOTSTRAP_ADMIN_USER
const bootstrapPass = process.env.BOOTSTRAP_ADMIN_PASS
const hasAnyAdmin = db.prepare('SELECT id FROM admins LIMIT 1').get()

if (!hasAnyAdmin && bootstrapUser && bootstrapPass) {
  const hash = bcrypt.hashSync(bootstrapPass, 12)
  db.prepare('INSERT INTO admins (usuario, password) VALUES (?, ?)').run(bootstrapUser, hash)
  console.log('Admin bootstrap creado desde variables de entorno.')
} else if (!hasAnyAdmin) {
  console.warn('No hay admins. Define BOOTSTRAP_ADMIN_USER y BOOTSTRAP_ADMIN_PASS para crear el primero.')
}

module.exports = db
