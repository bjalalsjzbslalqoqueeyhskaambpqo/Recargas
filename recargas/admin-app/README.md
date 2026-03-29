# Admin App (Android) - Base compilable

Esta app ya tiene estructura mínima Android y compila en CI.

## Archivo de datos desde servidor
`local/bootstrap.properties` con:
- `API_BASE_URL`
- `APP_ADMIN_KEY`
- `DEFAULT_ADMIN_USER`
- `DEFAULT_ADMIN_PASSWORD`

Ese archivo lo genera `recargas/install.sh` y también imprime el bloque para copiar/pegar.

## Compilación en workflow
GitHub Actions instala JDK + Android SDK + Gradle, compila `assembleRelease` y firma automáticamente.

> Para producción real, cambia la firma efímera por una keystore fija tuya.
