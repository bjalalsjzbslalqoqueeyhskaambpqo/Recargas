# Client App (Android)

App Android de cliente conectada a endpoints `/api/client/*`.

## Bootstrap local
Archivo: `local/bootstrap.properties`

```properties
API_BASE_URL=http://IP:80
APP_CLIENT_KEY=...
DEFAULT_CLIENT_USER=...
```

También se pueden enviar estas variables por entorno al compilar (`API_BASE_URL`, `APP_CLIENT_KEY`, `DEFAULT_CLIENT_USER`) y tienen prioridad sobre el archivo.

## CI / GitHub Actions
El workflow `client-app-build.yml` ahora funciona así:

1. Si `local/bootstrap.properties` ya existe en el repo, lo respeta.
2. Solo sobreescribe campos puntuales cuando hay secretos no vacíos en GitHub (`API_BASE_URL`, `APP_CLIENT_KEY`, `DEFAULT_CLIENT_USER`).
3. Imprime en logs el `bootstrap` final usado para compilar.

Esto evita que el build vuelva por defecto a `127.0.0.1` cuando el secreto está vacío.

## Solución cuando sigue apuntando a `127.0.0.1`
Si ya actualizaste `bootstrap.properties` pero la app instalada sigue mostrando `127.0.0.1`, recompila e instala nuevamente para regenerar `BuildConfig`:

```bash
cd client-android-app
./gradlew clean :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

> Nota: esta app **no** guarda ni usa credenciales de administrador.
