const { chromium } = require('playwright-extra')
const stealth = require('puppeteer-extra-plugin-stealth')
chromium.use(stealth())

async function intentarConTarjeta(numero, tarjeta, monto) {
  const browser = await chromium.launch({ headless: true })
  const page = await browser.newPage()

  try {
    await page.goto('https://www.movistar.com.ar/recarga-con-tarjeta-de-credito')

    const inputAni = page.locator('#ani')
    await inputAni.waitFor({ state: 'visible', timeout: 15000 })
    await inputAni.click()
    await inputAni.type(numero, { delay: 200 })
    await page.keyboard.press('Tab')
    await page.locator('.pnt-mensaje-valido').waitFor({ state: 'visible', timeout: 15000 })

    const frame = page.frame({ name: 'my_frame' })
    if (!frame) {
      await browser.close()
      return { ok: false, mensaje: 'iframe no cargó' }
    }

    await frame.locator('#numerotarjeta').waitFor({ state: 'visible', timeout: 10000 })
    await frame.fill('#numerotarjeta', tarjeta.numero)
    await frame.fill('#mes', tarjeta.mes)
    await frame.fill('#anio', tarjeta.anio)
    await frame.fill('#pass', tarjeta.cvv)
    await frame.click('#btn_validar')

    await page.waitForFunction(
      () => window.location.href.includes('tokenDatosRecarga'),
      { timeout: 20000 }
    )

    await page.locator('select.pnt-js-combo-importe-recarga').waitFor({ state: 'visible', timeout: 10000 })
    await page.evaluate((m) => {
      const select = document.querySelector('select.pnt-js-combo-importe-recarga')
      if (select) {
        select.value = m
        select.dispatchEvent(new Event('change', { bubbles: true }))
      }
    }, monto)

    await page.locator('.pnt-js-btn-recargar').waitFor({ state: 'visible', timeout: 5000 })

    const [response] = await Promise.all([
      page.waitForResponse(
        res => res.url().includes('cargarCredito') && res.request().method() === 'GET',
        { timeout: 25000 }
      ),
      page.locator('.pnt-js-btn-recargar').click()
    ])

    const data = await response.json()
    await browser.close()

    if (!data.isError) {
      return { ok: true, mensaje: 'Recarga exitosa' }
    }
    return { ok: false, mensaje: data.mensaje || 'Tarjeta rechazada' }

  } catch(e) {
    await browser.close()
    return { ok: false, mensaje: e.message }
  }
}

async function recargar(numero, monto, tarjetas) {
  for (let i = 0; i < tarjetas.length; i++) {
    console.log('Movistar: intentando tarjeta ' + (i + 1) + '...')
    const resultado = await intentarConTarjeta(numero, tarjetas[i], monto)
    console.log('Tarjeta ' + (i + 1) + ':', resultado)
    if (resultado.ok) return { ...resultado, tarjeta_idx: i }
  }
  return { ok: false, mensaje: 'Todas las tarjetas fallaron' }
}

module.exports = { recargar }
