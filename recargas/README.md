# Recargas - Admin API + App Android Admin

> Estado consolidado del proyecto (incluye qué está hecho vs pendiente de cliente nativo): `docs/ESTADO_PROYECTO.md`.

## Instalación del servidor (ahora sí despliega API)
Ejecuta:

```bash
cd recargas
./install.sh
```

El instalador te pide:
1. Directorio destino (ej: `/opt/recargas-admin`)
2. URL del repo git (opcional)

### Modos de instalación
- Si pones URL git: clona/pull en el directorio destino.
- Si no pones URL: copia los archivos locales actuales al directorio destino.
- Si no hay archivos base, crea estructura mínima para que luego pegues tu lógica.

Después:
- genera `.env`
- genera `admin-app/local/bootstrap.properties`
- ejecuta `npm install`
- configura y arranca `systemd` (si disponible)

## Datos para compilar APK
Al final imprime y guarda este bloque:

```properties
API_BASE_URL=http://IP_DEL_SERVIDOR:80
APP_ADMIN_KEY=...
DEFAULT_ADMIN_USER=...
DEFAULT_ADMIN_PASSWORD=...
```

## API Admin principal
- `GET /api/status`
- `POST /api/admin/login` (requiere header `X-App-Key`)
- `GET /api/admin/me`
- `PATCH /api/admin/me`
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

## API Cliente
- `POST /api/client/login` (requiere header `X-App-Key`)
- `GET /api/client/me`
- `GET /api/client/servicios`
- `GET /api/client/historial`
- `POST /api/client/recargar`

## Cliente web básico (nuevo)
- Ruta estática servida por la API: `GET /client`
- Archivos en `recargas/client-app/` (`index.html`, `app.js`, `styles.css`)
- Usa los endpoints `/api/client/*` para login, consulta de saldo, servicios y recargas.
- Por defecto lee:
  - `API_BASE`: `location.origin`
  - `APP_KEY`: `localStorage.app_key` (si no existe usa `dev-change-me`)
- CI de cliente: workflow `.github/workflows/client-app-build.yml` (valida `app.js` y sube artefacto web `client-app-web`).

## App Android Admin
- usa `admin-app/local/bootstrap.properties`
- prueba conexión a `/api/status`
- hace login a `/api/admin/login` con `X-App-Key`
