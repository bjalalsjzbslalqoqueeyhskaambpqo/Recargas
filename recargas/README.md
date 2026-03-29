# Recargas - Etapa Admin API + Bots base

Esta etapa deja únicamente lo necesario para:
- Servidor Admin API (HTTP)
- Gestión de usuarios/saldo/tarjetas/notificaciones
- Guardado de tarjetas para uso de bots
- Scripts de bots activos (`movistar` y `personal`)
- Base para compilar App Android Admin por GitHub Actions

## Instalación servidor
```bash
cd recargas
./install.sh
```

## API Admin principal
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

## Workflow Android Admin
Archivo: `.github/workflows/admin-android-build.yml`

Compila automáticamente el APK debug cuando subas la app completa en:
`recargas/admin-app/`

## Bots activos
- `server/bots/movistar/bot.js`
- `server/bots/personal/bot.js`
