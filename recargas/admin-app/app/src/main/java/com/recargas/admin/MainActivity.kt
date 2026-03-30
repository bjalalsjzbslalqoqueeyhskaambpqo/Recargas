package com.recargas.admin

import android.content.SharedPreferences
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.People
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

data class AdminUser(val id: Int, val usuario: String, val saldo: Double, val activo: Boolean)
data class AdminCard(val id: Int, val alias: String, val numero: String, val estado: String, val ultimoUso: String, val metricas: String)
data class AdminHist(val id: Int, val servicio: String, val referencia: String, val monto: Double, val estado: String, val fecha: String)

enum class AdminTab { Crear, Usuarios, Tarjetas, Historial }

data class AdminUiState(
    val user: String = BuildConfig.DEFAULT_ADMIN_USER,
    val pass: String = BuildConfig.DEFAULT_ADMIN_PASSWORD,
    val token: String? = null,
    val loading: Boolean = false,
    val serverText: String = "Comprobando servidor...",
    val isLoggedIn: Boolean = false,
    val summary: String = "",
    val unreadNotif: Int = 0,
    val tab: AdminTab = AdminTab.Crear,
    val users: List<AdminUser> = emptyList(),
    val cards: List<AdminCard> = emptyList(),
    val history: List<AdminHist> = emptyList(),
    val historyFilter: String = "todos",
    val newUser: String = "",
    val newPass: String = "",
    val newSaldo: String = "0",
    val cardAlias: String = "",
    val cardNumero: String = "",
    val cardMes: String = "",
    val cardAnio: String = "",
    val cardCvv: String = "",
    val snackbar: String? = null,
)

class MainActivity : ComponentActivity() {
    private val viewModel by viewModels<AdminViewModel> {
        val prefs = getSharedPreferences("admin_prefs", MODE_PRIVATE)
        AdminViewModelFactory(prefs)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            val state by viewModel.uiState.collectAsStateWithLifecycle()
            AdminTheme {
                AdminApp(state, viewModel)
            }
        }
    }
}

class AdminViewModelFactory(private val prefs: SharedPreferences) : ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        @Suppress("UNCHECKED_CAST")
        return AdminViewModel(prefs) as T
    }
}

class AdminViewModel(private val prefs: SharedPreferences) : ViewModel() {
    private val _uiState = MutableStateFlow(AdminUiState(
        user = prefs.getString("user", BuildConfig.DEFAULT_ADMIN_USER) ?: BuildConfig.DEFAULT_ADMIN_USER,
        pass = prefs.getString("pass", BuildConfig.DEFAULT_ADMIN_PASSWORD) ?: BuildConfig.DEFAULT_ADMIN_PASSWORD,
        token = prefs.getString("token", null),
        isLoggedIn = prefs.getString("token", null) != null
    ))
    val uiState: StateFlow<AdminUiState> = _uiState

    init {
        checkServer()
        if (_uiState.value.isLoggedIn) refreshAll()
    }

    fun updateUser(v: String) = _uiState.update { it.copy(user = v) }
    fun updatePass(v: String) = _uiState.update { it.copy(pass = v) }
    fun setTab(tab: AdminTab) = _uiState.update { it.copy(tab = tab) }
    fun setHistoryFilter(v: String) = _uiState.update { it.copy(historyFilter = v) }
    fun clearSnackbar() = _uiState.update { it.copy(snackbar = null) }

    fun updateCreateUser(v: String) = _uiState.update { it.copy(newUser = v) }
    fun updateCreatePass(v: String) = _uiState.update { it.copy(newPass = v) }
    fun updateCreateSaldo(v: String) = _uiState.update { it.copy(newSaldo = v) }
    fun updateCardAlias(v: String) = _uiState.update { it.copy(cardAlias = v) }
    fun updateCardNumero(v: String) = _uiState.update { it.copy(cardNumero = v) }
    fun updateCardMes(v: String) = _uiState.update { it.copy(cardMes = v) }
    fun updateCardAnio(v: String) = _uiState.update { it.copy(cardAnio = v) }
    fun updateCardCvv(v: String) = _uiState.update { it.copy(cardCvv = v) }

    fun login() {
        val s = _uiState.value
        _uiState.update { it.copy(loading = true) }
        postJson("/api/admin/login", JSONObject().put("usuario", s.user).put("password", s.pass), withAuth = false) { code, json ->
            if (code in 200..299 && json.has("token")) {
                val token = json.getString("token")
                prefs.edit().putString("user", s.user).putString("pass", s.pass).putString("token", token).apply()
                _uiState.update { it.copy(token = token, isLoggedIn = true, loading = false, snackbar = "Login correcto") }
                refreshAll()
            } else {
                _uiState.update { it.copy(loading = false, snackbar = json.optString("error", "Error de login")) }
            }
        }
    }

    fun logout() {
        prefs.edit().remove("token").apply()
        _uiState.update { it.copy(token = null, isLoggedIn = false) }
    }

    fun refreshAll() {
        loadSummary(); loadUsers(); loadCards(); loadHistory()
    }

    fun createUser() {
        val s = _uiState.value
        postJson("/api/admin/usuarios", JSONObject().put("usuario", s.newUser).put("password", s.newPass).put("saldo", s.newSaldo.toDoubleOrNull() ?: 0.0)) { code, json ->
            _uiState.update { it.copy(snackbar = if (code in 200..299) "Usuario creado" else json.optString("error", "Error creando usuario"), newUser = "", newPass = "", newSaldo = "0") }
            if (code in 200..299) refreshAll()
        }
    }

    fun addCard() {
        val s = _uiState.value
        val body = JSONObject().put("alias", s.cardAlias).put("numero", s.cardNumero).put("mes", s.cardMes).put("anio", s.cardAnio).put("cvv", s.cardCvv)
        postJson("/api/admin/tarjetas", body) { code, json ->
            _uiState.update {
                it.copy(
                    snackbar = if (code in 200..299) "Tarjeta agregada ✓" else json.optString("error", "Error tarjeta"),
                    cardAlias = "", cardNumero = "", cardMes = "", cardAnio = "", cardCvv = ""
                )
            }
            if (code in 200..299) refreshAll()
        }
    }

    fun deleteCard(cardId: Int) {
        deleteJson("/api/admin/tarjetas/$cardId") { code, json ->
            _uiState.update { it.copy(snackbar = if (code in 200..299) "Tarjeta eliminada" else json.optString("error", "Error al eliminar")) }
            if (code in 200..299) refreshAll()
        }
    }

    fun toggleCard(cardId: Int, activa: Boolean) {
        patchJson("/api/admin/tarjetas/$cardId/activa", JSONObject().put("activa", if (activa) 1 else 0)) { code, json ->
            _uiState.update { it.copy(snackbar = if (code in 200..299) "Tarjeta actualizada" else json.optString("error", "Error al actualizar")) }
            if (code in 200..299) loadCards()
        }
    }

    private fun checkServer() {
        request("/api/status", "GET", null, withAuth = false) { code, _ ->
            _uiState.update { it.copy(serverText = if (code in 200..299) "Servidor conectado" else "Servidor error HTTP $code") }
        }
    }

    private fun loadSummary() {
        authorizedGet("/api/admin/usuarios") { c1, uRaw ->
            if (c1 !in 200..299) return@authorizedGet
            val users = JSONArray(uRaw)
            authorizedGet("/api/admin/tarjetas") { c2, tRaw ->
                if (c2 !in 200..299) return@authorizedGet
                val cards = JSONArray(tRaw)
                authorizedGet("/api/admin/notificaciones") { c3, nRaw ->
                    val count = if (c3 in 200..299) JSONArray(nRaw).length() else 0
                    _uiState.update { it.copy(summary = "Usuarios: ${users.length()} | Tarjetas: ${cards.length()} | Notificaciones: $count", unreadNotif = count) }
                }
            }
        }
    }

    private fun loadUsers() {
        authorizedGet("/api/admin/usuarios") { code, raw ->
            if (code !in 200..299) return@authorizedGet
            val arr = JSONArray(raw)
            _uiState.update {
                it.copy(users = (0 until arr.length()).map { idx ->
                    val o = arr.getJSONObject(idx)
                    AdminUser(o.optInt("id"), o.optString("usuario"), o.optDouble("saldo"), o.optInt("activo") == 1)
                })
            }
        }
    }

    private fun loadCards() {
        authorizedGet("/api/admin/tarjetas") { code, raw ->
            if (code !in 200..299) return@authorizedGet
            val arr = JSONArray(raw)
            _uiState.update {
                it.copy(cards = (0 until arr.length()).map { idx ->
                    val o = arr.getJSONObject(idx)
                    val metricas = o.optJSONArray("metricas")
                    val sum = if (metricas == null || metricas.length() == 0) "Sin métricas" else {
                        (0 until metricas.length()).joinToString(" · ") { mi ->
                            val m = metricas.getJSONObject(mi)
                            "✓ ${m.optInt("exitos")} ✗ ${m.optInt("fallos")} c:${m.optInt("fallos_consecutivos")}"
                        }
                    }
                    val estado = when {
                        o.optInt("ignorada") == 1 -> "BLOQUEADA"
                        o.optInt("activa") == 1 -> "ACTIVA"
                        else -> "INACTIVA"
                    }
                    AdminCard(o.optInt("id"), o.optString("alias", "Sin alias"), o.optString("numero"), estado, o.optString("ultimo_uso", "Sin uso aún"), sum)
                })
            }
        }
    }

    private fun loadHistory() {
        authorizedGet("/api/admin/historial") { code, raw ->
            if (code !in 200..299) return@authorizedGet
            val arr = JSONArray(raw)
            _uiState.update {
                it.copy(history = (0 until arr.length()).map { idx ->
                    val o = arr.getJSONObject(idx)
                    AdminHist(o.optInt("id"), o.optString("servicio"), o.optString("referencia"), o.optDouble("monto"), o.optString("estado"), o.optString("fecha"))
                })
            }
        }
    }

    private fun token() = _uiState.value.token

    private fun authorizedGet(path: String, onDone: (Int, String) -> Unit) = request(path, "GET", null, true, onDone)
    private fun postJson(path: String, body: JSONObject, withAuth: Boolean = true, onDone: (Int, JSONObject) -> Unit) =
        request(path, "POST", body.toString(), withAuth) { c, raw -> onDone(c, parseJson(raw)) }
    private fun patchJson(path: String, body: JSONObject, onDone: (Int, JSONObject) -> Unit) =
        request(path, "PATCH", body.toString(), true) { c, raw -> onDone(c, parseJson(raw)) }
    private fun deleteJson(path: String, onDone: (Int, JSONObject) -> Unit) =
        request(path, "DELETE", null, true) { c, raw -> onDone(c, parseJson(raw)) }

    private fun request(path: String, method: String, body: String?, withAuth: Boolean = true, onDone: (Int, String) -> Unit) {
        val tk = token()
        thread {
            try {
                val conn = URL("${BuildConfig.API_BASE_URL}$path").openConnection() as HttpURLConnection
                conn.requestMethod = method
                conn.setRequestProperty("Content-Type", "application/json")
                conn.setRequestProperty("X-App-Key", BuildConfig.APP_ADMIN_KEY)
                if (withAuth && tk != null) conn.setRequestProperty("Authorization", "Bearer $tk")
                conn.connectTimeout = 8000
                conn.readTimeout = 8000
                if (body != null) {
                    conn.doOutput = true
                    OutputStreamWriter(conn.outputStream).use { it.write(body) }
                }
                val code = conn.responseCode
                val text = (if (code in 200..299) conn.inputStream else conn.errorStream).bufferedReader().use(BufferedReader::readText)
                viewModelScope.launch { onDone(code, text) }
            } catch (e: Exception) {
                viewModelScope.launch { onDone(500, "{\"error\":\"${e.message}\"}") }
            }
        }
    }

    private fun parseJson(raw: String): JSONObject = try { JSONObject(raw) } catch (_: Exception) { JSONObject() }
}

@Composable
fun AdminApp(state: AdminUiState, vm: AdminViewModel) {
    val snackbarHostState = remember { SnackbarHostState() }
    LaunchedEffect(state.snackbar) {
        state.snackbar?.let { snackbarHostState.showSnackbar(it); vm.clearSnackbar() }
    }

    if (!state.isLoggedIn) {
        LoginScreen(state, vm)
        return
    }

    Scaffold(snackbarHost = { SnackbarHost(snackbarHostState) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Card(colors = CardDefaults.cardColors(containerColor = Color(0xFF1A1D27))) {
                Column(Modifier.fillMaxWidth().padding(14.dp)) {
                    Text("Admin Recargas", color = Color(0xFFF1F3F9), style = MaterialTheme.typography.titleLarge)
                    Text(state.summary, color = Color(0xFF8B92A9))
                }
            }
            TabRow(selectedTabIndex = state.tab.ordinal) {
                AdminTab.entries.forEach { tab ->
                    Tab(selected = state.tab == tab, onClick = { vm.setTab(tab) }, text = { Text(tab.name) }, icon = {
                        Icon(when (tab) {
                            AdminTab.Crear -> Icons.Default.AccountCircle
                            AdminTab.Usuarios -> Icons.Default.People
                            AdminTab.Tarjetas -> Icons.Default.CreditCard
                            AdminTab.Historial -> Icons.Default.History
                        }, null)
                    })
                }
            }
            when (state.tab) {
                AdminTab.Crear -> CreateTab(state, vm)
                AdminTab.Usuarios -> UsersTab(state)
                AdminTab.Tarjetas -> CardsTab(state, vm)
                AdminTab.Historial -> HistoryTab(state, vm)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = vm::refreshAll) { Text("Actualizar") }
                TextButton(onClick = vm::logout) { Text("Salir") }
            }
        }
    }
}

@Composable
private fun LoginScreen(state: AdminUiState, vm: AdminViewModel) {
    Column(
        Modifier.fillMaxSize().background(Color(0xFF0F1117)).padding(20.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Icon(Icons.Default.Lock, null, tint = Color(0xFF4F6EF7), modifier = Modifier.size(64.dp))
        Spacer(Modifier.height(12.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Spacer(Modifier.size(8.dp).background(if (state.serverText.contains("conectado")) Color(0xFF22C55E) else Color(0xFFEF4444), CircleShape))
            Spacer(Modifier.size(8.dp))
            Text(state.serverText, color = Color(0xFF8B92A9))
        }
        Spacer(Modifier.height(12.dp))
        OutlinedTextField(value = state.user, onValueChange = vm::updateUser, label = { Text("Usuario") }, leadingIcon = { Icon(Icons.Default.AccountCircle, null) }, modifier = Modifier.fillMaxWidth())
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(value = state.pass, onValueChange = vm::updatePass, label = { Text("Contraseña") }, visualTransformation = PasswordVisualTransformation(), leadingIcon = { Icon(Icons.Default.Lock, null) }, modifier = Modifier.fillMaxWidth())
        Spacer(Modifier.height(8.dp))
        Button(onClick = vm::login, modifier = Modifier.fillMaxWidth().height(52.dp), enabled = !state.loading) {
            if (state.loading) CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp) else Text("Ingresar")
        }
    }
}

@Composable
private fun CreateTab(state: AdminUiState, vm: AdminViewModel) {
    LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { Text("Crear usuario", color = Color(0xFFF1F3F9)) }
        item { OutlinedTextField(value = state.newUser, onValueChange = vm::updateCreateUser, label = { Text("Usuario") }, modifier = Modifier.fillMaxWidth()) }
        item { OutlinedTextField(value = state.newPass, onValueChange = vm::updateCreatePass, label = { Text("Password") }, modifier = Modifier.fillMaxWidth()) }
        item { OutlinedTextField(value = state.newSaldo, onValueChange = vm::updateCreateSaldo, label = { Text("Saldo") }, modifier = Modifier.fillMaxWidth()) }
        item { Button(onClick = vm::createUser, modifier = Modifier.fillMaxWidth()) { Text("Crear") } }
    }
}

@Composable
private fun UsersTab(state: AdminUiState) {
    LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        items(state.users) { u ->
            Card(colors = CardDefaults.cardColors(containerColor = Color(0xFF1A1D27))) {
                Column(Modifier.fillMaxWidth().padding(12.dp)) {
                    Text(u.usuario, color = Color(0xFFF1F3F9))
                    Text("Saldo: ${u.saldo}", color = if (u.saldo > 0) Color(0xFF22C55E) else Color(0xFF8B92A9))
                    AssistChip(onClick = {}, label = { Text(if (u.activo) "ACTIVO" else "INACTIVO") }, enabled = false)
                }
            }
        }
    }
}

@Composable
private fun CardsTab(state: AdminUiState, vm: AdminViewModel) {
    var deleteId by remember { mutableStateOf<Int?>(null) }
    if (deleteId != null) {
        AlertDialog(onDismissRequest = { deleteId = null }, confirmButton = {
            TextButton(onClick = { vm.deleteCard(deleteId!!); deleteId = null }) { Text("Eliminar") }
        }, dismissButton = { TextButton(onClick = { deleteId = null }) { Text("Cancelar") } }, title = { Text("Confirmar") }, text = { Text("¿Eliminar tarjeta?") })
    }
    LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { Text("Agregar tarjeta", color = Color(0xFFF1F3F9)) }
        item { OutlinedTextField(value = state.cardAlias, onValueChange = vm::updateCardAlias, label = { Text("Alias") }, modifier = Modifier.fillMaxWidth()) }
        item { OutlinedTextField(value = state.cardNumero, onValueChange = vm::updateCardNumero, label = { Text("Número") }, modifier = Modifier.fillMaxWidth()) }
        item { Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(value = state.cardMes, onValueChange = vm::updateCardMes, label = { Text("Mes") }, modifier = Modifier.weight(1f))
            OutlinedTextField(value = state.cardAnio, onValueChange = vm::updateCardAnio, label = { Text("Año") }, modifier = Modifier.weight(1f))
            OutlinedTextField(value = state.cardCvv, onValueChange = vm::updateCardCvv, label = { Text("CVV") }, modifier = Modifier.weight(1f))
        }}
        item { Button(onClick = vm::addCard, modifier = Modifier.fillMaxWidth()) { Text("Agregar tarjeta ✓") } }
        items(state.cards) { c ->
            Card(colors = CardDefaults.cardColors(containerColor = Color(0xFF1A1D27)), shape = RoundedCornerShape(16.dp)) {
                Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("${c.alias} ${c.numero}", color = Color(0xFFF1F3F9))
                    Text("Último uso: ${c.ultimoUso}", color = Color(0xFF8B92A9))
                    Text(c.metricas, color = Color(0xFF8B92A9))
                    AssistChip(onClick = {}, label = { Text(c.estado) }, enabled = false)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton(onClick = { vm.toggleCard(c.id, c.estado != "ACTIVA") }) { Text(if (c.estado == "ACTIVA") "Deshabilitar" else "Habilitar") }
                        TextButton(onClick = { deleteId = c.id }) { Text("Eliminar") }
                    }
                }
            }
        }
    }
}

@Composable
private fun HistoryTab(state: AdminUiState, vm: AdminViewModel) {
    val filtered = state.history.filter {
        when (state.historyFilter) {
            "ok" -> it.estado.contains("ok", true)
            "fallo" -> it.estado.contains("fallo", true)
            else -> true
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("todos", "ok", "fallo").forEach { f ->
                FilterChip(selected = state.historyFilter == f, onClick = { vm.setHistoryFilter(f) }, label = { Text(f) })
            }
        }
        if (filtered.isEmpty()) {
            Text("Sin historial", color = Color(0xFF8B92A9))
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(filtered) { h ->
                    Card(colors = CardDefaults.cardColors(containerColor = Color(0xFF1A1D27))) {
                        Column(Modifier.fillMaxWidth().padding(12.dp)) {
                            Text("${h.servicio} - ${h.monto}", color = Color(0xFFF1F3F9))
                            Text("${h.referencia} | ${h.fecha}", color = Color(0xFF8B92A9))
                            AssistChip(onClick = {}, label = { Text(h.estado) }, enabled = false)
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun AdminTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = androidx.compose.material3.darkColorScheme(
            background = Color(0xFF0F1117),
            surface = Color(0xFF1A1D27),
            surfaceVariant = Color(0xFF222536),
            primary = Color(0xFF4F6EF7),
            secondary = Color(0xFF06B6D4),
            error = Color(0xFFEF4444),
            onBackground = Color(0xFFF1F3F9),
            onSurface = Color(0xFFF1F3F9)
        ),
        content = content
    )
}
