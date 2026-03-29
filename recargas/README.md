# Recargas

## Arquitectura (eficiente)
- **App Node**: corre interno en `127.0.0.1:3000`.
- **Gateway Go**: corre en `:443` (HTTPS), expone solo `https://dominio/recargas`.
- El gateway reescribe `/recargas/*` hacia la app interna (`/`).

## Instalación rápida
```bash
cd recargas
./install.sh
```

### Flujo del instalador
1. Espera 5 segundos y abre editor para pegar **Origin Certificate** de Cloudflare.
2. Guardas y sales del editor (en nano: `Ctrl+X`).
3. Espera 5 segundos y abre editor para pegar **Private Key** de Cloudflare.
4. Guardas y sales del editor.
5. Pide usuario y contraseña del **admin inicial**.
6. Pide dominio y ruta pública (por defecto `/recargas`).
7. Compila gateway Go, instala dependencias Node y configura `systemd`.

Resultado esperado:
- `https://TU_DOMINIO/recargas`
- `https://TU_DOMINIO/recargas/admin`

## Agregar un nuevo bot (sin tocar backend)
1. Crear carpeta: `server/bots/<nombre_servicio>/`
2. Agregar `ui.html`
3. Agregar `bot.js` exportando mínimo:

```js
async function procesar({ referencia, monto, usuario }) {
  return { ok: true, mensaje: 'Procesado' }
}
module.exports = { procesar }
```

Opcional:
- `nombre`
- `montos`
- `validarReferencia(referencia)`
- `disponible` (`false` para ocultar)
