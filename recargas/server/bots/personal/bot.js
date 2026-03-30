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
    await page.locator('button:has-text("Confirmar")').click()

    await page.waitForFunction(() => {
      const t = document.body.innerText
      return t.includes('Confirmar el pago') || t.includes('Pagar') ||
             t.includes('exitosa') || t.includes('aprobada') || t.includes('Gracias') ||
             t.includes('No pudimos') || t.includes('rechazada') || t.includes('error')
    }, { timeout: 30000 })

    const textoPago = await page.evaluate(() => document.body.innerText)
    if (textoPago.includes('Confirmar el pago') || textoPago.includes('Pagar')) {
      await page.locator('button:has-text("Pagar")').click()
      await page.waitForFunction(() => {
        const t = document.body.innerText
        return t.includes('exitosa') || t.includes('aprobada') || t.includes('Gracias') ||
               t.includes('No pudimos') || t.includes('rechazada') || t.includes('error')
      }, { timeout: 30000 })
    }

    const texto = await page.evaluate(() => document.body.innerText)
    await browser.close()

    if (texto.includes('exitosa') || texto.includes('aprobada') || texto.includes('Gracias')) {
      return { ok: true, mensaje: 'Recarga exitosa' }
    }
    return { ok: false, mensaje: 'Tarjeta rechazada' }

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
    if (resultado.ok) return { ...resultado, tarjeta_idx: i }
  }
  return { ok: false, mensaje: 'Servicio no disponible' }
}

module.exports = { recargar }
