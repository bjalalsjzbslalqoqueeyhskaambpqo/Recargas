# Admin App (Android) - Base funcional

La app abre login admin y, al autenticar, muestra panel con acciones reales.

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
- Guarda credenciales exitosas y token en `SharedPreferences`
- Login contra `POST /api/admin/login` enviando `X-App-Key`
- Panel admin con opciones:
  - Crear usuario
  - Agregar tarjeta
  - Ver usuarios, tarjetas, historial, notificaciones
  - Actualizar sus propias credenciales admin
- Solicita permiso de notificaciones y hace polling liviano (30s) para avisar nuevas alertas.

## Nota HTTP por IP
La app permite tráfico HTTP (cleartext) para usar IP:80 en entorno controlado.
