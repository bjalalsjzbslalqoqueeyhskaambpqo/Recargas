# Recargas Admin API (HTTP)

Backend centrado en administración (sin páginas web), pensado para app Android Admin.

## Qué incluye
- Login admin
- Gestión de usuarios (crear, eliminar, ajustar saldo +/-)
- Historial admin
- Gestión de tarjetas
- Métricas de fallos por tarjeta/servicio con auto-ignorado y notificación

## Instalación
```bash
cd recargas
./install.sh
```

## Endpoints base
- `GET /api/status`
- `POST /api/admin/login`
- `GET /api/admin/usuarios`
- `POST /api/admin/usuarios`
- `DELETE /api/admin/usuarios/:id`
- `PATCH /api/admin/usuarios/:id/saldo`
- `GET /api/admin/historial`
- `GET /api/admin/tarjetas`
- `POST /api/admin/tarjetas`
- `PATCH /api/admin/tarjetas/:id/activa`
- `DELETE /api/admin/tarjetas/:id`
- `POST /api/admin/tarjetas/:id/resultado`
- `GET /api/admin/notificaciones`
- `PATCH /api/admin/notificaciones/:id/leida`

## Regla de auto-ignorado de tarjeta
El servidor ignora una tarjeta automáticamente cuando:
- acumula `>= 5` fallos consecutivos globales, o
- venía con al menos 1 éxito y luego llega a `>= 4` fallos consecutivos en un servicio.

Al ignorarse:
- se marca `ignorada=1`, `activa=0`
- se crea notificación para el admin.
