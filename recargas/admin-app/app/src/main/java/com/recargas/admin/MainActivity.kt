package com.recargas.admin

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.google.android.material.chip.Chip
import com.google.android.material.snackbar.Snackbar
import com.recargas.admin.databinding.ActivityMainBinding
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
    private var lastNotifId = 0

    private val prefs by lazy { getSharedPreferences("admin_prefs", MODE_PRIVATE) }
    private val handler = Handler(Looper.getMainLooper())
    private val notifRunnable = object : Runnable {
        override fun run() {
            if (authToken != null) pollNotificationsSilently()
            handler.postDelayed(this, 30000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        createNotificationChannel()
        requestNotifPermissionIfNeeded()

        val savedUser = prefs.getString("user", BuildConfig.DEFAULT_ADMIN_USER) ?: BuildConfig.DEFAULT_ADMIN_USER
        val savedPass = prefs.getString("pass", BuildConfig.DEFAULT_ADMIN_PASSWORD) ?: BuildConfig.DEFAULT_ADMIN_PASSWORD
        binding.inputUser.setText(savedUser)
        binding.inputPass.setText(savedPass)

        checkServer()

        binding.btnLogin.setOnClickListener {
            doLogin(binding.inputUser.text.toString().trim(), binding.inputPass.text.toString())
        }

        binding.btnRefresh.setOnClickListener { loadSummary() }
        binding.btnSecCreate.setOnClickListener { showSection(binding.secCreateUser) }
        binding.btnSecUsers.setOnClickListener {
            showSection(binding.secUsers)
            loadUsers()
        }
        binding.btnSecCards.setOnClickListener {
            showSection(binding.secCards)
            loadCards()
        }
        binding.btnSecHistory.setOnClickListener {
            showSection(binding.secHistory)
            loadHistory()
        }
        binding.btnSecNotif.setOnClickListener {
            showSection(binding.secNotif)
            loadNotifications()
        }
        binding.btnSecSettings.setOnClickListener { showSection(binding.secSettings) }
        binding.btnTarjetas.setOnClickListener { loadCards() }
        binding.btnHistorial.setOnClickListener { loadHistory() }
        binding.btnNotif.setOnClickListener { loadNotifications() }
        binding.btnReloadUsers.setOnClickListener { loadUsers() }
        binding.btnLogout.setOnClickListener { logout() }
        binding.btnCreateUser.setOnClickListener { createUser() }
        binding.btnAddCard.setOnClickListener { addCard() }
        binding.btnUpdateMe.setOnClickListener { updateMe() }

        authToken = prefs.getString("token", null)
        if (authToken != null) {
            showDashboard(savedUser)
            loadSummary()
        }

        handler.postDelayed(notifRunnable, 15000)
    }

    override fun onDestroy() {
        super.onDestroy()
        handler.removeCallbacks(notifRunnable)
    }

    private fun saveSession(user: String, pass: String, token: String) {
        prefs.edit().putString("user", user).putString("pass", pass).putString("token", token).apply()
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
                    binding.txtServer.text = if (code in 200..299) "Servidor: conectado (${BuildConfig.API_BASE_URL})" else "Servidor: error HTTP $code"
                }
            } catch (e: Exception) {
                runOnUiThread { binding.txtServer.text = "Servidor: sin conexión (${e.message})" }
            }
        }
    }

    private fun doLogin(user: String, pass: String) {
        binding.txtStatus.text = "Estado: iniciando sesión..."
        val body = JSONObject().put("usuario", user).put("password", pass)

        postJson("/api/admin/login", body, withAuth = false) { code, json ->
            if (code in 200..299 && json.has("token")) {
                authToken = json.getString("token")
                saveSession(user, pass, authToken!!)
                binding.txtStatus.text = "Estado: login OK"
                showDashboard(user)
                loadSummary()
            } else {
                binding.txtStatus.text = "Estado: fallo login (${json.optString("error", "sin detalle")})"
            }
        }
    }

    private fun showDashboard(user: String) {
        binding.loginPanel.visibility = View.GONE
        binding.dashboardPanel.visibility = View.VISIBLE
        binding.txtWelcome.text = "Bienvenido, $user"
        showSection(binding.secCreateUser)
    }

    private fun showSection(section: View) {
        binding.secCreateUser.visibility = View.GONE
        binding.secUsers.visibility = View.GONE
        binding.secCards.visibility = View.GONE
        binding.secHistory.visibility = View.GONE
        binding.secNotif.visibility = View.GONE
        binding.secSettings.visibility = View.GONE
        section.visibility = View.VISIBLE
    }

    private fun logout() {
        authToken = null
        prefs.edit().remove("token").apply()
        binding.dashboardPanel.visibility = View.GONE
        binding.loginPanel.visibility = View.VISIBLE
        binding.txtStatus.text = "Estado: sesión cerrada"
    }

    private fun authorizedGet(path: String, onDone: (Int, String) -> Unit) {
        val token = authToken ?: return
        thread {
            try {
                val url = URL("${BuildConfig.API_BASE_URL}$path")
                val conn = url.openConnection() as HttpURLConnection
                conn.requestMethod = "GET"
                conn.setRequestProperty("Authorization", "Bearer $token")
                conn.setRequestProperty("X-App-Key", BuildConfig.APP_ADMIN_KEY)
                conn.connectTimeout = 8000
                conn.readTimeout = 8000

                val code = conn.responseCode
                val text = (if (code in 200..299) conn.inputStream else conn.errorStream).bufferedReader().use(BufferedReader::readText)
                runOnUiThread { onDone(code, text) }
            } catch (e: Exception) {
                runOnUiThread { onDone(500, "{\"error\":\"${e.message}\"}") }
            }
        }
    }

    private fun postJson(path: String, body: JSONObject, withAuth: Boolean = true, onDone: (Int, JSONObject) -> Unit) {
        thread {
            try {
                val url = URL("${BuildConfig.API_BASE_URL}$path")
                val conn = url.openConnection() as HttpURLConnection
                conn.requestMethod = "POST"
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json")
                conn.setRequestProperty("X-App-Key", BuildConfig.APP_ADMIN_KEY)
                if (withAuth && authToken != null) conn.setRequestProperty("Authorization", "Bearer $authToken")
                conn.connectTimeout = 8000
                conn.readTimeout = 8000

                OutputStreamWriter(conn.outputStream).use { it.write(body.toString()) }
                val code = conn.responseCode
                val response = (if (code in 200..299) conn.inputStream else conn.errorStream).bufferedReader().use(BufferedReader::readText)
                runOnUiThread { onDone(code, JSONObject(response)) }
            } catch (e: Exception) {
                runOnUiThread { onDone(500, JSONObject().put("error", e.message ?: "error")) }
            }
        }
    }

    private fun patchJson(path: String, body: JSONObject, onDone: (Int, JSONObject) -> Unit) {
        thread {
            try {
                val url = URL("${BuildConfig.API_BASE_URL}$path")
                val conn = url.openConnection() as HttpURLConnection
                conn.requestMethod = "PATCH"
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json")
                conn.setRequestProperty("X-App-Key", BuildConfig.APP_ADMIN_KEY)
                conn.setRequestProperty("Authorization", "Bearer $authToken")
                conn.connectTimeout = 8000
                conn.readTimeout = 8000

                OutputStreamWriter(conn.outputStream).use { it.write(body.toString()) }
                val code = conn.responseCode
                val response = (if (code in 200..299) conn.inputStream else conn.errorStream).bufferedReader().use(BufferedReader::readText)
                runOnUiThread { onDone(code, JSONObject(response)) }
            } catch (e: Exception) {
                runOnUiThread { onDone(500, JSONObject().put("error", e.message ?: "error")) }
            }
        }
    }

    private fun deleteJson(path: String, onDone: (Int, JSONObject) -> Unit) {
        thread {
            try {
                val url = URL("${BuildConfig.API_BASE_URL}$path")
                val conn = url.openConnection() as HttpURLConnection
                conn.requestMethod = "DELETE"
                conn.setRequestProperty("Content-Type", "application/json")
                conn.setRequestProperty("X-App-Key", BuildConfig.APP_ADMIN_KEY)
                conn.setRequestProperty("Authorization", "Bearer $authToken")
                conn.connectTimeout = 8000
                conn.readTimeout = 8000

                val code = conn.responseCode
                val response = (if (code in 200..299) conn.inputStream else conn.errorStream).bufferedReader().use(BufferedReader::readText)
                runOnUiThread { onDone(code, JSONObject(response)) }
            } catch (e: Exception) {
                runOnUiThread { onDone(500, JSONObject().put("error", e.message ?: "error")) }
            }
        }
    }

    private fun loadSummary() {
        authorizedGet("/api/admin/usuarios") { c1, usersRaw ->
            if (c1 !in 200..299) {
                binding.txtSummary.text = "Resumen: error usuarios"
                return@authorizedGet
            }
            val users = JSONArray(usersRaw)
            authorizedGet("/api/admin/tarjetas") { c2, cardsRaw ->
                if (c2 !in 200..299) {
                    binding.txtSummary.text = "Resumen: error tarjetas"
                    return@authorizedGet
                }
                val cards = JSONArray(cardsRaw)
                authorizedGet("/api/admin/notificaciones") { c3, notifRaw ->
                    val notifCount = if (c3 in 200..299) JSONArray(notifRaw).length() else -1
                    binding.txtSummary.text = "Usuarios: ${users.length()} | Tarjetas: ${cards.length()} | Notificaciones: $notifCount"
                }
            }
        }
    }

    private fun createUser() {
        val user = binding.newUser.text.toString().trim()
        val pass = binding.newPass.text.toString()
        val saldo = binding.newSaldo.text.toString().ifBlank { "0" }.toDoubleOrNull() ?: 0.0
        val body = JSONObject().put("usuario", user).put("password", pass).put("saldo", saldo)
        postJson("/api/admin/usuarios", body) { code, json ->
            binding.txtData.text = if (code in 200..299) "Usuario creado: ${json.optString("usuario")}" else "Error crear usuario: ${json.optString("error")}" 
            if (code in 200..299) loadSummary()
        }
    }

    private fun addCard() {
        val body = JSONObject()
            .put("alias", binding.cardAlias.text.toString().trim())
            .put("numero", binding.cardNumber.text.toString().trim())
            .put("mes", binding.cardMes.text.toString().trim())
            .put("anio", binding.cardAnio.text.toString().trim())
            .put("cvv", binding.cardCvv.text.toString().trim())

        postJson("/api/admin/tarjetas", body) { code, json ->
            binding.txtData.text = if (code in 200..299) "Tarjeta agregada. ID=${json.optInt("id")}" else "Error tarjeta: ${json.optString("error")}"
            if (code in 200..299) {
                binding.cardAlias.text?.clear()
                binding.cardNumber.text?.clear()
                binding.cardMes.text?.clear()
                binding.cardAnio.text?.clear()
                binding.cardCvv.text?.clear()
                Snackbar.make(binding.rootLayout, "Tarjeta agregada", Snackbar.LENGTH_SHORT).show()
                loadSummary()
                loadCards()
            }
        }
    }

    private fun updateMe() {
        val body = JSONObject()
        val newUser = binding.meUser.text.toString().trim()
        val newPass = binding.mePass.text.toString()
        if (newUser.isNotBlank()) body.put("usuario", newUser)
        if (newPass.isNotBlank()) body.put("password", newPass)
        if (body.length() == 0) {
            binding.txtData.text = "Nada para actualizar."
            return
        }

        patchJson("/api/admin/me", body) { code, json ->
            if (code in 200..299) {
                val finalUser = json.optJSONObject("admin")?.optString("usuario") ?: binding.inputUser.text.toString()
                val finalPass = if (newPass.isNotBlank()) newPass else binding.inputPass.text.toString()
                prefs.edit().putString("user", finalUser).putString("pass", finalPass).apply()
                binding.inputUser.setText(finalUser)
                binding.inputPass.setText(finalPass)
                binding.txtData.text = "Credenciales admin actualizadas."
            } else {
                binding.txtData.text = "Error actualizar perfil: ${json.optString("error")}" 
            }
        }
    }

    private fun loadUsers() {
        authorizedGet("/api/admin/usuarios") { code, raw ->
            if (code !in 200..299) {
                binding.txtData.text = "Error usuarios: $raw"
                return@authorizedGet
            }
            val arr = JSONArray(raw)
            renderUsers(arr)
            binding.txtData.text = "Usuarios cargados: ${arr.length()}"
        }
    }

    private fun renderUsers(arr: JSONArray) {
        binding.usersContainer.removeAllViews()
        if (arr.length() == 0) {
            val empty = TextView(this).apply { text = "No hay usuarios." }
            binding.usersContainer.addView(empty)
            return
        }

        for (i in 0 until arr.length()) {
            val u = arr.getJSONObject(i)
            val userId = u.optInt("id")
            val username = u.optString("usuario")
            val saldo = u.optDouble("saldo")
            val activo = u.optInt("activo") == 1

            val card = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(20, 16, 20, 16)
            }
            val title = TextView(this).apply {
                text = "$username (ID $userId)"
                textSize = 16f
            }
            val meta = TextView(this).apply {
                text = "Saldo: $saldo | Activo: ${if (activo) "Sí" else "No"}"
            }
            val actions = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
            }
            val btnSaldo = Button(this).apply {
                text = "Saldo +/-"
                setOnClickListener { promptSaldoDelta(userId, username) }
            }
            val btnEdit = Button(this).apply {
                text = "Editar"
                setOnClickListener { promptEditUser(u) }
            }
            val btnDelete = Button(this).apply {
                text = "Eliminar"
                setOnClickListener {
                    AlertDialog.Builder(this@MainActivity)
                        .setTitle("Eliminar usuario")
                        .setMessage("¿Eliminar a $username?")
                        .setPositiveButton("Eliminar") { _, _ -> deleteUser(userId, username) }
                        .setNegativeButton("Cancelar", null)
                        .show()
                }
            }

            actions.addView(btnSaldo)
            actions.addView(btnEdit)
            actions.addView(btnDelete)
            card.addView(title)
            card.addView(meta)
            card.addView(actions)
            binding.usersContainer.addView(card)
        }
    }

    private fun promptSaldoDelta(userId: Int, username: String) {
        val input = EditText(this).apply { hint = "Ej: 100 o -50" }
        AlertDialog.Builder(this)
            .setTitle("Ajustar saldo de $username")
            .setView(input)
            .setPositiveButton("Aplicar") { _, _ ->
                val delta = input.text.toString().trim().toDoubleOrNull()
                if (delta == null || delta == 0.0) {
                    binding.txtData.text = "Delta inválido para $username"
                    return@setPositiveButton
                }
                patchJson("/api/admin/usuarios/$userId/saldo", JSONObject().put("delta", delta)) { code, json ->
                    if (code in 200..299) {
                        binding.txtData.text = "Saldo actualizado para $username: ${json.optDouble("saldo")}"
                        loadUsers()
                        loadSummary()
                    } else {
                        binding.txtData.text = "Error saldo $username: ${json.optString("error")}"
                    }
                }
            }
            .setNegativeButton("Cancelar", null)
            .show()
    }

    private fun promptEditUser(user: JSONObject) {
        val userId = user.optInt("id")
        val currentUser = user.optString("usuario")
        val currentSaldo = user.optDouble("saldo")
        val currentActivo = user.optInt("activo") == 1

        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 20, 32, 0)
        }
        val inputUser = EditText(this).apply {
            hint = "Usuario"
            setText(currentUser)
        }
        val inputPass = EditText(this).apply {
            hint = "Nueva password (opcional)"
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD
        }
        val inputSaldo = EditText(this).apply {
            hint = "Saldo absoluto"
            setText(currentSaldo.toString())
            inputType = android.text.InputType.TYPE_CLASS_NUMBER or android.text.InputType.TYPE_NUMBER_FLAG_DECIMAL or android.text.InputType.TYPE_NUMBER_FLAG_SIGNED
        }
        val inputActivo = EditText(this).apply {
            hint = "Activo 1 o 0"
            setText(if (currentActivo) "1" else "0")
            inputType = android.text.InputType.TYPE_CLASS_NUMBER
        }
        container.addView(inputUser)
        container.addView(inputPass)
        container.addView(inputSaldo)
        container.addView(inputActivo)

        AlertDialog.Builder(this)
            .setTitle("Editar usuario")
            .setView(container)
            .setPositiveButton("Guardar") { _, _ ->
                val body = JSONObject()
                body.put("usuario", inputUser.text.toString().trim())
                val pass = inputPass.text.toString()
                if (pass.isNotBlank()) body.put("password", pass)
                body.put("saldo", inputSaldo.text.toString().trim().toDoubleOrNull() ?: currentSaldo)
                body.put("activo", if (inputActivo.text.toString().trim() == "1") 1 else 0)

                patchJson("/api/admin/usuarios/$userId", body) { code, json ->
                    if (code in 200..299) {
                        binding.txtData.text = "Usuario actualizado: ${json.optJSONObject("usuario")?.optString("usuario", currentUser)}"
                        loadUsers()
                        loadSummary()
                    } else {
                        binding.txtData.text = "Error al editar usuario: ${json.optString("error")}"
                    }
                }
            }
            .setNegativeButton("Cancelar", null)
            .show()
    }

    private fun deleteUser(userId: Int, username: String) {
        deleteJson("/api/admin/usuarios/$userId") { code, json ->
            if (code in 200..299) {
                binding.txtData.text = "Usuario eliminado: $username"
                loadUsers()
                loadSummary()
            } else {
                binding.txtData.text = "Error eliminando $username: ${json.optString("error")}"
            }
        }
    }

    private fun loadCards() {
        authorizedGet("/api/admin/tarjetas") { code, raw ->
            if (code !in 200..299) {
                binding.txtData.text = "Error tarjetas: $raw"
                return@authorizedGet
            }
            val arr = JSONArray(raw)
            renderCards(arr)
            binding.txtData.text = "Tarjetas cargadas: ${arr.length()}"
        }
    }

    private fun renderCards(arr: JSONArray) {
        binding.cardsContainer.removeAllViews()
        if (arr.length() == 0) {
            val empty = TextView(this).apply { text = "No hay tarjetas." }
            binding.cardsContainer.addView(empty)
            return
        }

        for (i in 0 until arr.length()) {
            val t = arr.getJSONObject(i)
            val cardId = t.optInt("id")
            val alias = t.optString("alias", "").ifBlank { "Sin alias" }
            val numero = t.optString("numero")
            val activa = t.optInt("activa") == 1
            val ignorada = t.optInt("ignorada") == 1

            val card = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(24, 20, 24, 20)
                setBackgroundColor(0xFFF2F5FF.toInt())
            }
            val title = TextView(this).apply {
                text = "$alias (ID $cardId)"
                textSize = 18f
            }
            val estado = when {
                ignorada -> "Ignorada"
                activa -> "Activa"
                else -> "Inactiva"
            }
            val meta = TextView(this).apply {
                val ultUso = t.optString("ultimo_uso", "N/D")
                val ultEstado = t.optString("ultimo_estado", "-")
                val ultServicio = t.optString("ultimo_servicio", "-")
                text = "$numero | Últ. uso: $ultUso | Estado: $ultEstado | Servicio: $ultServicio"
            }
            val metrics = TextView(this).apply {
                val metricas = t.optJSONArray("metricas")
                val metricsText = if (metricas == null || metricas.length() == 0) {
                    "Sin métricas de uso todavía"
                } else {
                    (0 until metricas.length()).joinToString(" | ") { idx ->
                        val m = metricas.getJSONObject(idx)
                        "${m.optString("servicio")}: i=${m.optInt("intentos")} ok=${m.optInt("exitos")} f=${m.optInt("fallos")} fc=${m.optInt("fallos_consecutivos")}"
                    }
                }
                text = "Mes/Año: ${t.optString("mes")}/${t.optString("anio")} • $metricsText"
            }
            val statusChip = Chip(this).apply {
                text = estado
                isCheckable = false
                isClickable = false
                setChipBackgroundColorResource(if (estado == "Activa") android.R.color.holo_green_light else if (estado == "Ignorada") android.R.color.holo_orange_light else android.R.color.holo_red_light)
            }
            val actions = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
            }
            val btnToggle = Button(this).apply {
                text = if (activa) "Deshabilitar" else "Habilitar"
                isEnabled = !ignorada
                setOnClickListener { patchCardActiva(cardId, !activa, alias) }
            }
            val btnDelete = Button(this).apply {
                text = "Eliminar"
                setOnClickListener {
                    AlertDialog.Builder(this@MainActivity)
                        .setTitle("Eliminar tarjeta")
                        .setMessage("¿Eliminar la tarjeta $alias ($numero)?")
                        .setPositiveButton("Eliminar") { _, _ -> deleteCard(cardId, alias) }
                        .setNegativeButton("Cancelar", null)
                        .show()
                }
            }

            actions.addView(btnToggle)
            actions.addView(btnDelete)
            card.addView(title)
            card.addView(meta)
            card.addView(metrics)
            card.addView(statusChip)
            card.addView(actions)
            binding.cardsContainer.addView(card)
        }
    }

    private fun patchCardActiva(cardId: Int, activa: Boolean, alias: String) {
        patchJson("/api/admin/tarjetas/$cardId/activa", JSONObject().put("activa", if (activa) 1 else 0)) { code, json ->
            if (code in 200..299) {
                binding.txtData.text = "Tarjeta ${if (activa) "habilitada" else "deshabilitada"}: $alias"
                loadCards()
            } else {
                binding.txtData.text = "Error tarjeta $alias: ${json.optString("error")}"
            }
        }
    }

    private fun deleteCard(cardId: Int, alias: String) {
        deleteJson("/api/admin/tarjetas/$cardId") { code, json ->
            if (code in 200..299) {
                binding.txtData.text = "Tarjeta eliminada: $alias"
                loadCards()
                loadSummary()
            } else {
                binding.txtData.text = "Error al eliminar tarjeta $alias: ${json.optString("error")}"
            }
        }
    }

    private fun loadHistory() {
        authorizedGet("/api/admin/historial") { code, raw ->
            if (code !in 200..299) {
                binding.txtData.text = "Error historial: $raw"
                return@authorizedGet
            }
            val arr = JSONArray(raw)
            val lines = mutableListOf("Historial (${arr.length()}):")
            for (i in 0 until minOf(arr.length(), 30)) {
                val h = arr.getJSONObject(i)
                lines.add("- ${h.optString("fecha")} | ${h.optString("servicio")} | ${h.optString("estado")}")
            }
            binding.txtData.text = lines.joinToString("\n")
        }
    }

    private fun loadNotifications() {
        authorizedGet("/api/admin/notificaciones") { code, raw ->
            if (code !in 200..299) {
                binding.txtData.text = "Error notificaciones: $raw"
                return@authorizedGet
            }
            val arr = JSONArray(raw)
            val lines = mutableListOf("Notificaciones (${arr.length()}):")
            for (i in 0 until minOf(arr.length(), 30)) {
                val n = arr.getJSONObject(i)
                lines.add("- ${n.optString("creada")} | ${n.optString("mensaje")}")
            }
            binding.txtData.text = lines.joinToString("\n")
        }
    }

    private fun pollNotificationsSilently() {
        authorizedGet("/api/admin/notificaciones") { code, raw ->
            if (code !in 200..299) return@authorizedGet
            val arr = JSONArray(raw)
            if (arr.length() == 0) return@authorizedGet
            val latest = arr.getJSONObject(0)
            val id = latest.optInt("id", 0)
            if (id > lastNotifId) {
                lastNotifId = id
                sendLocalNotification("Admin Recargas", latest.optString("mensaje", "Nueva notificación"))
            }
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel("admin_channel", "Admin Recargas", NotificationManager.IMPORTANCE_DEFAULT)
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun requestNotifPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33 && ActivityCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
    }

    private fun sendLocalNotification(title: String, body: String) {
        if (Build.VERSION.SDK_INT >= 33 && ActivityCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            return
        }
        val builder = NotificationCompat.Builder(this, "admin_channel")
            .setSmallIcon(android.R.drawable.stat_notify_more)
            .setContentTitle(title)
            .setContentText(body)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
        NotificationManagerCompat.from(this).notify((System.currentTimeMillis() % Int.MAX_VALUE).toInt(), builder.build())
    }
}
