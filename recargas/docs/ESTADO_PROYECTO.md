# Estado del proyecto Recargas (Servidor + Admin + Cliente)

> Fecha de actualización: 2026-03-30

## 1) Qué está terminado hoy

### Servidor/API (Node + Express + SQLite)
- API base levantada en `recargas/server/index.js` con:
  - seguridad por `helmet`
  - límite de login (`express-rate-limit`)
  - autenticación JWT para admin y usuario
  - validaciones de entrada básicas
- Persistencia en SQLite (`better-sqlite3`) con esquema en `recargas/server/db.js`.
- Módulo de bots cargado dinámicamente desde `recargas/server/bots/*/bot.js`.
- Lógica administrativa implementada:
  - login admin
  - gestión de usuarios (crear/listar/editar/saldo/eliminar)
  - gestión de tarjetas
  - historial
  - notificaciones
- Lógica cliente API implementada:
  - login usuario
  - ver perfil/saldo
  - listar servicios disponibles por bots
  - recargar
  - historial del usuario

### App Android Admin (sí compila en su pipeline dedicado)
- Proyecto en `recargas/admin-app`.
- Pantalla de administración conectada con la API admin.
- CI dedicado: `.github/workflows/admin-android-build.yml`.
- El pipeline genera APK release firmado y publica artefactos.

### Cliente actual
- Existe **cliente web básico** en `recargas/client-app`.
- CI dedicado: `.github/workflows/client-app-build.yml`.
- El flujo actual del cliente en CI **no compila una app móvil nativa**; valida JS y empaqueta artefacto web estático.

---

## 2) Qué NO está terminado (pendiente real)

### App de cliente “de verdad” (nativa)
- No hay app Android/iOS cliente final lista para distribución.
- El cliente actual es web estático (MVP operativo), no app móvil compilada de producción.

### Calidad/producción
- Falta suite de tests automática (unit/integration/e2e).
- Falta observabilidad más completa (métricas, trazas, alertas).
- Falta endurecimiento adicional de seguridad para producción (rotación de secretos, políticas más estrictas, hardening extra).

---

## 3) Configuración clave del servidor (operación)

Variables mínimas necesarias (ver `.env.example`):
- `SECRET` (>= 32 chars)
- `APP_ADMIN_KEY` (>= 24 chars)
- `BOOTSTRAP_ADMIN_USER`
- `BOOTSTRAP_ADMIN_PASS`
- `PORT`
- `BIND_HOST`

El servidor no inicia si faltan `SECRET` o `APP_ADMIN_KEY` con longitudes mínimas válidas.

---

## 4) Plan Admin (ya implementado)

1. Login admin contra `/api/admin/login` con `X-App-Key`.
2. Carga de resumen y secciones de gestión.
3. Gestión de usuarios:
   - crear
   - editar
   - ajustar saldo
   - activar/desactivar
   - eliminar
4. Gestión de tarjetas:
   - crear
   - activar/desactivar
   - eliminar
   - registrar resultados
5. Consulta de historial y notificaciones.

---

## 5) Plan Cliente (handoff para continuar)

Base lista en API:
1. Login `/api/client/login`.
2. Perfil/saldo `/api/client/me`.
3. Catálogo de servicios `/api/client/servicios`.
4. Recarga `/api/client/recargar`.
5. Historial `/api/client/historial`.

### Recomendación para la app cliente nativa
- Reusar estos endpoints sin cambiar contrato.
- Implementar app cliente separada (`client-android-app` o similar), con:
  - login persistente
  - dashboard de saldo
  - selector de servicio/monto
  - historial filtrable
  - manejo robusto de errores/red

---

## 6) Archivos de referencia rápida
- Servidor API: `recargas/server/index.js`
- DB esquema/bootstrap: `recargas/server/db.js`
- Bots: `recargas/server/bots/`
- App Admin Android: `recargas/admin-app/`
- Cliente web actual: `recargas/client-app/`
- CI Admin APK: `.github/workflows/admin-android-build.yml`
- CI Cliente web: `.github/workflows/client-app-build.yml`
