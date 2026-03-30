const { chromium } = require('playwright-extra')
const stealth = require('puppeteer-extra-plugin-stealth')
chromium.use(stealth())

async function intentarConTarjeta(numero, tarjeta, monto) {
  const browser = await chromium.launch({ headless: true })
  const page = await browser.newPage()
  await page.setViewportSize({ width: 390, height: 844 })

  try {
    await page.goto('https://recargas.personal.com.ar/phone')

    const inputNumero = page.locator('input[placeholder*="1153394581"]')
    await inputNumero.waitFor({ state: 'visible', timeout: 15000 })
    await inputNumero.type(numero, { delay: 150 })
    await page.locator('button[type="submit"]').click()
    await page.waitForURL('**/pay/amount**', { timeout: 15000 })

    await page.getByText('$' + Number(monto).toLocaleString('es-AR')).first().click()

    const inputNumeroTarjeta = page.locator('#number')
    await inputNumeroTarjeta.waitFor({ state: 'visible', timeout: 10000 })
    await inputNumeroTarjeta.fill(tarjeta.numero)
    await page.locator('button:has-text("Siguiente")').click()

    const inputExpiry = page.locator('#expiry')
    await inputExpiry.waitFor({ state: 'visible', timeout: 10000 })
    await inputExpiry.fill(tarjeta.mes + '/' + tarjeta.anio)
    await page.locator('button:has-text("Siguiente")').click()

    const inputCvc = page.locator('#cvc')
    await inputCvc.waitFor({ state: 'visible', timeout: 10000 })
    await inputCvc.fill(tarjeta.cvv)

    const [response] = await Promise.all([
      page.waitForResponse(
        res => res.url().includes('/api/lines/') && res.url().includes('/recharges'),
        { timeout: 30000 }
      ),
      page.locator('button:has-text("Confirmar")').click()
    ])

    const data = await response.json()
    await browser.close()

    if (data.message === 'No fue posible procesar el pago de la recarga.') {
      return { ok: false, mensaje: 'Tarjeta rechazada' }
    }
    return { ok: true, mensaje: 'Recarga exitosa' }

  } catch(e) {
    await browser.close()
    return { ok: false, mensaje: e.message }
  }
}

async function recargar(numero, monto, tarjetas) {
  for (let i = 0; i < tarjetas.length; i++) {
    console.log('Personal: intentando tarjeta ' + (i + 1) + '...')
    const resultado = await intentarConTarjeta(numero, tarjetas[i], monto)
    console.log('Tarjeta ' + (i + 1) + ':', resultado)
    if (resultado.ok) return { ok: true, mensaje: resultado.mensaje, tarjeta_idx: i }
    resultado.tarjeta_idx = i
  }
  return { ok: false, mensaje: 'Servicio no disponible', tarjeta_idx: 0 }
}

module.exports = { recargar }
