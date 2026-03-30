package com.recargas.client

import org.json.JSONArray
import org.json.JSONObject

class ClientRepository(private val apiClient: ApiClient = ApiClient()) {
    fun checkServer(onDone: (Boolean, String) -> Unit) {
        apiClient.request("/api/status", "GET", null, token = null) { code, raw ->
            if (code in 200..299) onDone(true, "Servidor conectado")
            else onDone(false, "Servidor con error HTTP $code")
        }
    }

    fun login(user: String, pass: String, onDone: (Int, JSONObject) -> Unit) {
        apiClient.postJson("/api/client/login", JSONObject().put("usuario", user).put("password", pass), null, onDone = onDone)
    }

    fun me(token: String, onDone: (Int, JSONObject) -> Unit) = apiClient.getJson("/api/client/me", token, onDone)

    fun servicios(token: String, onDone: (Int, JSONArray) -> Unit) = apiClient.getJsonArray("/api/client/servicios", token, onDone)

    fun historial(token: String, onDone: (Int, JSONArray) -> Unit) = apiClient.getJsonArray("/api/client/historial", token, onDone)

    fun recargar(token: String, servicio: String, monto: Double, referencia: String, onDone: (Int, JSONObject) -> Unit) {
        val payload = JSONObject().put("servicio", servicio).put("monto", monto).put("referencia", referencia)
        apiClient.postJson("/api/client/recargar", payload, token = token, readTimeoutMs = 120_000, onDone = onDone)
    }
}
