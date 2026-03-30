const nombre = 'Movistar'
const montos = [2000, 4000, 6000, 10000]

function validarReferencia(referencia) {
  return /^\d{10}$/.test(referencia)
}

async function procesar({ referencia, monto }) {
  await new Promise(resolve => setTimeout(resolve, 2500))
  if (!validarReferencia(referencia)) {
    return { ok: false, mensaje: 'Número inválido para Movistar.' }
  }
  return { ok: true, mensaje: `Recarga Movistar de $${monto} enviada a ${referencia}.` }
}

module.exports = { nombre, montos, validarReferencia, procesar }
