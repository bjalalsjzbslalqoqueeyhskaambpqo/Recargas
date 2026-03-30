const { chromium } = require('playwright-extra')
const stealth = require('puppeteer-extra-plugin-stealth')
chromium.use(stealth())

async function intentarConTarjeta(numero, tarjeta, monto) {
  const browser = await chromium.launch({ headless: true })
  const page = await browser.newPage()
  await page.setViewportSize({ width: 390, height: 844 })

  try {
    await page.goto('https://recargas.personal.com.ar/phone')
    await page.waitForSelector('input[placeholder*="1153394581"]', { timeout: 15000 })
    await page.type('input[placeholder*="1153394581"]', numero, { delay: 150 })
    await page.click('button[type="submit"]')
    await page.waitForURL('**/pay/amount**', { timeout: 15000 })
    await page.waitForTimeout(3000)

    await page.getByText('$' + Number(monto).toLocaleString('es-AR')).first().click()
    await page.waitForTimeout(3000)

    await page.fill('#number', tarjeta.numero)
    await page.click('button:has-text("Siguiente")')
    await page.waitForTimeout(2000)

    await page.fill('#expiry', tarjeta.mes + '/' + tarjeta.anio)
    await page.click('button:has-text("Siguiente")')
    await page.waitForTimeout(2000)

    await page.fill('#cvc', tarjeta.cvv)
    await page.click('button:has-text("Confirmar")')
    await page.waitForTimeout(3000)

    const textoPago = await page.evaluate(() => document.body.innerText)
    if (textoPago.includes('Confirmar el pago') || textoPago.includes('Pagar')) {
      await page.click('button:has-text("Pagar")')
    }

    try {
      await page.waitForFunction(() => {
        const t = document.body.innerText
        return t.includes('exitosa') || t.includes('aprobada') || t.includes('Gracias') ||
               t.includes('No pudimos') || t.includes('rechazada') || t.includes('error')
      }, { timeout: 25000 })
    } catch(e) {}

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
