# Recargas - Admin API + App Android Admin

## 1) Instalación del servidor (automática)
Ejecuta desde la carpeta `recargas`:

```bash
cd recargas
./install.sh
```

No hace preguntas:
- Detecta IP local de la máquina
- Usa puerto `80`
- Genera usuario/pass admin por defecto
- Genera `APP_ADMIN_KEY`
- Escribe `admin-app/local/bootstrap.properties`
- Instala dependencias y levanta servicio `recargas-admin-api`

## 2) Datos para compilar APK
Al terminar, el instalador imprime este bloque:

```properties
API_BASE_URL=http://IP_DE_TU_SERVIDOR:80
APP_ADMIN_KEY=...
DEFAULT_ADMIN_USER=...
DEFAULT_ADMIN_PASSWORD=...
```

Ese mismo bloque queda guardado en:
`recargas/admin-app/local/bootstrap.properties`

## 3) Compilación Android en GitHub Actions
Workflow: `.github/workflows/admin-android-build.yml`
- Corre en cualquier rama
- Instala Java 17 + Android SDK + Gradle
- Genera keystore JKS temporal
- Compila `assembleRelease` firmado
- Sube:
  - `admin-signed-release-apk`
  - `admin-signing-data`

## 4) API Admin principal
- `GET /api/status`
- `POST /api/admin/login` (requiere header `X-App-Key`)
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

## Bots activos
- `server/bots/movistar/bot.js`
- `server/bots/personal/bot.js`
