# Admin App (Android) - Placeholder

Aquí irá la app Android del administrador.

## Archivo clave que genera el instalador
`bootstrap-config.json` con:
- `api_base_url`
- `x_app_key`
- `default_admin_user`
- `default_admin_password`

## Para que el workflow compile
Esta carpeta debe incluir proyecto Android completo con:
- `gradlew`
- `settings.gradle` o `settings.gradle.kts`
- módulo `app/`

## Firma automática en GitHub Actions
El workflow genera automáticamente:
- `android-signing.jks`
- credenciales de firma (`signing-data.txt`)

y compila `assembleRelease` firmado.

> Para entorno productivo, reemplaza esta firma efímera por una keystore fija y segura.
