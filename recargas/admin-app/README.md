# Admin App (Android) - Base funcional

La app abre directamente pantalla de login admin.

## Datos que consume desde build
Archivo: `local/bootstrap.properties`

```properties
API_BASE_URL=http://IP:80
APP_ADMIN_KEY=...
DEFAULT_ADMIN_USER=...
DEFAULT_ADMIN_PASSWORD=...
```

El instalador del servidor (`recargas/install.sh`) genera este archivo automáticamente.

## Comportamiento actual
- Al abrir, prueba conexión con `GET /api/status`
- Prellena usuario y contraseña por defecto
- Login contra `POST /api/admin/login` enviando `X-App-Key`
