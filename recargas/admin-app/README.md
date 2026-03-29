# Admin App (Android) - Placeholder

Aquí irá la app Android del administrador.

## Archivo clave que genera el instalador
`bootstrap-config.json` con:
- `api_base_url`
- `x_app_key`
- `default_admin_user`
- `default_admin_password`

Ese archivo se usa para configurar rápidamente la compilación del APK.

## Estructura esperada
- `app/`
- `build.gradle` / `settings.gradle`
- `gradlew`

Cuando subas el proyecto completo en esta carpeta,
GitHub Actions compilará un APK debug automáticamente.
