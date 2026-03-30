package com.recargas.client

import android.os.Bundle
import android.view.View
import android.widget.ArrayAdapter
import androidx.appcompat.app.AppCompatActivity
import com.recargas.client.databinding.ActivityMainBinding
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

class MainActivity : AppCompatActivity() {
    private lateinit var binding: ActivityMainBinding
    private var authToken: String? = null
    private val prefs by lazy { getSharedPreferences("client_prefs", MODE_PRIVATE) }
    private var servicios = JSONArray()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.inputUser.setText(prefs.getString("user", BuildConfig.DEFAULT_CLIENT_USER))
        checkServer()

        authToken = prefs.getString("token", null)
        if (authToken != null) {
            showApp(true)
            loadMeServiciosHistorial()
        }

        binding.btnLogin.setOnClickListener { doLogin() }
        binding.btnRefresh.setOnClickListener { loadMeServiciosHistorial() }
        binding.btnRecargar.setOnClickListener { doRecargar() }
        binding.btnLogout.setOnClickListener {
            authToken = null
            prefs.edit().remove("token").apply()
            showApp(false)
        }

        binding.spServicio.setOnItemSelectedListener(object : android.widget.AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: View?, position: Int, id: Long) {
                setMontos(position)
            }

            override fun onNothingSelected(parent: android.widget.AdapterView<*>?) = Unit
        })
    }

    private fun showApp(show: Boolean) {
        binding.loginPanel.visibility = if (show) View.GONE else View.VISIBLE
        binding.appPanel.visibility = if (show) View.VISIBLE else View.GONE
    }

    private fun checkServer() {
        thread {
            try {
                val conn = URL("${BuildConfig.API_BASE_URL}/api/status").openConnection() as HttpURLConnection
                conn.requestMethod = "GET"
                val code = conn.responseCode
                runOnUiThread { binding.txtServer.text = if (code in 200..299) "Servidor: conectado" else "Servidor: error HTTP $code" }
            } catch (e: Exception) {
                runOnUiThread { binding.txtServer.text = "Servidor: sin conexión (${e.message})" }
            }
        }
    }

    private fun doLogin() {
        val user = binding.inputUser.text.toString().trim()
        val pass = binding.inputPass.text.toString()
        val payload = JSONObject().put("usuario", user).put("password", pass)

        postJson("/api/client/login", payload, withAuth = false) { code, json ->
            if (code in 200..299 && json.has("token")) {
                authToken = json.getString("token")
                prefs.edit().putString("user", user).putString("token", authToken).apply()
                binding.txtLoginMsg.text = "Estado: login OK"
                showApp(true)
                loadMeServiciosHistorial()
            } else {
                binding.txtLoginMsg.text = "Estado: ${json.optString("error", "falló login")}"
            }
        }
    }

    private fun loadMeServiciosHistorial() {
        getJson("/api/client/me") { code, me ->
            if (code !in 200..299) {
                binding.txtResult.text = "Error perfil: ${me.optString("error")}"; return@getJson
            }
            binding.txtWelcome.text = "Hola, ${me.optString("usuario", "cliente")}"
            binding.txtSaldo.text = "Saldo: \$${"%.2f".format(me.optDouble("saldo", 0.0))}"

            getJsonArray("/api/client/servicios") { c2, srv ->
                if (c2 !in 200..299) {
                    binding.txtResult.text = "Error servicios"; return@getJsonArray
                }
                servicios = srv
                val nombres = (0 until srv.length()).map { idx -> srv.getJSONObject(idx).optString("nombre", "servicio") }
                binding.spServicio.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, nombres)
                if (srv.length() > 0) setMontos(0)

                getJsonArray("/api/client/historial") { c3, hist ->
                    if (c3 !in 200..299) {
                        binding.txtHistorial.text = "No disponible"; return@getJsonArray
                    }
                    binding.txtHistorial.text = if (hist.length() == 0) "Sin movimientos" else {
                        buildString {
                            for (i in 0 until hist.length()) {
                                val h = hist.getJSONObject(i)
                                append("• ${h.optString("fecha")} | ${h.optString("servicio")} | ${h.optString("estado")}\n")
                            }
                        }
                    }
                }
            }
        }
    }

    private fun setMontos(serviceIndex: Int) {
        if (serviceIndex < 0 || serviceIndex >= servicios.length()) return
        val montos = servicios.getJSONObject(serviceIndex).optJSONArray("montos") ?: JSONArray()
        val values = (0 until montos.length()).map { montos.get(it).toString() }
        binding.spMonto.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, values)
    }

    private fun doRecargar() {
        val serviceIndex = binding.spServicio.selectedItemPosition
        if (serviceIndex < 0 || serviceIndex >= servicios.length()) return
        val serviceId = servicios.getJSONObject(serviceIndex).optString("id")
        val monto = binding.spMonto.selectedItem?.toString()?.toDoubleOrNull() ?: 0.0
        val referencia = binding.inputReferencia.text.toString().trim()

        val payload = JSONObject()
            .put("servicio", serviceId)
            .put("monto", monto)
            .put("referencia", referencia)

        postJson("/api/client/recargar", payload) { code, out ->
            binding.txtResult.text = if (code in 200..299) {
                "OK: ${out.optString("mensaje", "recarga enviada")}"
            } else {
                "Error: ${out.optString("error", "falló")}"
            }
            loadMeServiciosHistorial()
        }
    }

    private fun getJson(path: String, onDone: (Int, JSONObject) -> Unit) {
        request(path, "GET", null) { code, raw ->
            onDone(code, parseJson(raw))
        }
    }

    private fun getJsonArray(path: String, onDone: (Int, JSONArray) -> Unit) {
        request(path, "GET", null) { code, raw ->
            onDone(code, parseArray(raw))
        }
    }

    private fun postJson(path: String, body: JSONObject, withAuth: Boolean = true, onDone: (Int, JSONObject) -> Unit) {
        request(path, "POST", body.toString(), withAuth) { code, raw ->
            onDone(code, parseJson(raw))
        }
    }

    private fun request(path: String, method: String, body: String?, withAuth: Boolean = true, onDone: (Int, String) -> Unit) {
        val token = authToken
        thread {
            try {
                val url = URL("${BuildConfig.API_BASE_URL}$path")
                val conn = url.openConnection() as HttpURLConnection
                conn.requestMethod = method
                conn.setRequestProperty("Content-Type", "application/json")
                conn.setRequestProperty("X-App-Key", BuildConfig.APP_CLIENT_KEY)
                if (withAuth && token != null) conn.setRequestProperty("Authorization", "Bearer $token")
                conn.connectTimeout = 8000
                conn.readTimeout = 8000

                if (body != null) {
                    conn.doOutput = true
                    OutputStreamWriter(conn.outputStream).use { it.write(body) }
                }

                val code = conn.responseCode
                val text = (if (code in 200..299) conn.inputStream else conn.errorStream).bufferedReader().use(BufferedReader::readText)
                runOnUiThread { onDone(code, text) }
            } catch (e: Exception) {
                runOnUiThread { onDone(500, "{\"error\":\"${e.message}\"}") }
            }
        }
    }

    private fun parseJson(raw: String): JSONObject = try { JSONObject(raw) } catch (_: Exception) { JSONObject() }
    private fun parseArray(raw: String): JSONArray = try { JSONArray(raw) } catch (_: Exception) { JSONArray() }
}
