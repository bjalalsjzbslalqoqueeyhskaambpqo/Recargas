package com.recargas.admin

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import com.recargas.admin.databinding.ActivityMainBinding
import org.json.JSONObject
import java.io.BufferedReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

class MainActivity : AppCompatActivity() {
    private lateinit var binding: ActivityMainBinding

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.inputUser.setText(BuildConfig.DEFAULT_ADMIN_USER)
        binding.inputPass.setText(BuildConfig.DEFAULT_ADMIN_PASSWORD)

        checkServer()

        binding.btnLogin.setOnClickListener {
            val user = binding.inputUser.text.toString().trim()
            val pass = binding.inputPass.text.toString()
            doLogin(user, pass)
        }
    }

    private fun checkServer() {
        thread {
            try {
                val url = URL("${BuildConfig.API_BASE_URL}/api/status")
                val conn = url.openConnection() as HttpURLConnection
                conn.requestMethod = "GET"
                conn.connectTimeout = 5000
                conn.readTimeout = 5000
                val code = conn.responseCode

                runOnUiThread {
                    binding.txtServer.text = if (code in 200..299) {
                        "Servidor: conectado (${BuildConfig.API_BASE_URL})"
                    } else {
                        "Servidor: error HTTP $code"
                    }
                }
            } catch (e: Exception) {
                runOnUiThread {
                    binding.txtServer.text = "Servidor: sin conexión (${e.message})"
                }
            }
        }
    }

    private fun doLogin(user: String, pass: String) {
        binding.txtStatus.text = "Estado: iniciando sesión..."

        thread {
            try {
                val url = URL("${BuildConfig.API_BASE_URL}/api/admin/login")
                val conn = url.openConnection() as HttpURLConnection
                conn.requestMethod = "POST"
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json")
                conn.setRequestProperty("X-App-Key", BuildConfig.APP_ADMIN_KEY)
                conn.connectTimeout = 8000
                conn.readTimeout = 8000

                val body = JSONObject().put("usuario", user).put("password", pass).toString()
                OutputStreamWriter(conn.outputStream).use { it.write(body) }

                val code = conn.responseCode
                val response = (if (code in 200..299) conn.inputStream else conn.errorStream).bufferedReader().use(BufferedReader::readText)
                val json = JSONObject(response)

                runOnUiThread {
                    if (code in 200..299 && json.has("token")) {
                        binding.txtStatus.text = "Estado: login OK"
                    } else {
                        binding.txtStatus.text = "Estado: fallo login (${json.optString("error", "sin detalle")})"
                    }
                }
            } catch (e: Exception) {
                runOnUiThread {
                    binding.txtStatus.text = "Estado: error (${e.message})"
                }
            }
        }
    }
}
