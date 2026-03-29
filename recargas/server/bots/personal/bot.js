const nombre = 'Personal'
const montos = [4000, 6000, 8000, 12000]

function validarReferencia(referencia) {
  return /^\d{10}$/.test(referencia)
}

async function procesar({ referencia, monto }) {
  await new Promise(resolve => setTimeout(resolve, 2200))
  if (!validarReferencia(referencia)) {
    return { ok: false, mensaje: 'Número inválido para Personal.' }
  }
  return { ok: true, mensaje: `Recarga Personal de $${monto} enviada a ${referencia}.` }
}

module.exports = { nombre, montos, validarReferencia, procesar }
