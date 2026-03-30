package com.recargas.client

import android.content.SharedPreferences
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AssistChip
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

data class Servicio(val id: String, val nombre: String, val disponible: Boolean, val montos: List<Double>)
data class Movimiento(
    val servicio: String,
    val monto: Double,
    val referencia: String,
    val fecha: String,
    val estado: String,
    val mensaje: String = ""
)

data class UltimaRecarga(
    val servicio: String,
    val monto: Double,
    val referencia: String,
    val fechaLocal: String,
    val estado: String,
    val mensaje: String,
    val pendiente: Boolean
)

data class ClientUiState(
    val isLoggedIn: Boolean = false,
    val user: String = "",
    val pass: String = "",
    val token: String? = null,
    val serverOk: Boolean = false,
    val serverText: String = "Comprobando servidor...",
    val loginLoading: Boolean = false,
    val loginMessage: String = "",
    val welcome: String = "Hola",
    val saldo: Double = 0.0,
    val servicios: List<Servicio> = emptyList(),
    val selectedServicio: Servicio? = null,
    val selectedMonto: Double? = null,
    val phone: String = "",
    val phoneValid: Boolean = false,
    val processingRecarga: Boolean = false,
    val movimientos: List<Movimiento> = emptyList(),
    val ultimaRecarga: UltimaRecarga? = null,
    val snackbarMessage: String? = null,
    val snackbarSuccess: Boolean = true,
)

class ClientViewModel(
    private val repository: ClientRepository,
    private val prefs: SharedPreferences
) : ViewModel() {
    @Volatile
    private var isRefreshing = false

    private val _uiState = MutableStateFlow(
        ClientUiState(
            user = prefs.getString("user", BuildConfig.DEFAULT_CLIENT_USER) ?: BuildConfig.DEFAULT_CLIENT_USER,
            token = prefs.getString("token", null),
            isLoggedIn = prefs.getString("token", null) != null
        )
    )
    val uiState: StateFlow<ClientUiState> = _uiState

    init {
        checkServer()
        if (_uiState.value.isLoggedIn) refreshData()
        startAutoRefresh()
    }

    fun updateUser(user: String) = _uiState.update { it.copy(user = user) }
    fun updatePass(pass: String) = _uiState.update { it.copy(pass = pass) }

    fun updatePhone(phone: String) {
        val clean = phone.take(10).filter { it.isDigit() }
        _uiState.update { it.copy(phone = clean, phoneValid = Regex("^\\d{10}$").matches(clean)) }
    }

    fun selectServicio(servicio: Servicio) = _uiState.update { it.copy(selectedServicio = servicio, selectedMonto = servicio.montos.firstOrNull()) }
    fun selectMonto(monto: Double) = _uiState.update { it.copy(selectedMonto = monto) }

    fun login() {
        val state = _uiState.value
        _uiState.update { it.copy(loginLoading = true, loginMessage = "") }
        repository.login(state.user, state.pass) { code, json ->
            if (code in 200..299 && json.has("token")) {
                val token = json.getString("token")
                prefs.edit().putString("user", state.user).putString("token", token).apply()
                _uiState.update { it.copy(token = token, isLoggedIn = true, loginLoading = false, loginMessage = "Login correcto") }
                refreshData()
            } else {
                _uiState.update { it.copy(loginLoading = false, loginMessage = json.optString("error", "Error de login")) }
            }
        }
    }

    fun logout() {
        prefs.edit().remove("token").apply()
        _uiState.update { it.copy(isLoggedIn = false, token = null, selectedServicio = null, selectedMonto = null, phone = "") }
    }

    fun onAppForeground() {
        if (_uiState.value.isLoggedIn) refreshData()
    }

    fun clearSnackbar() = _uiState.update { it.copy(snackbarMessage = null) }

    fun recargar() {
        val state = _uiState.value
        val token = state.token ?: return
        val servicio = state.selectedServicio ?: return
        val monto = state.selectedMonto ?: return
        if (!state.phoneValid) {
            _uiState.update { it.copy(snackbarMessage = "Número inválido (10 dígitos)", snackbarSuccess = false) }
            return
        }
        val fechaLocal = LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss"))
        val pendiente = UltimaRecarga(
            servicio = servicio.nombre,
            monto = monto,
            referencia = state.phone,
            fechaLocal = fechaLocal,
            estado = "procesando",
            mensaje = "Esperando confirmación del servidor...",
            pendiente = true
        )
        _uiState.update { it.copy(processingRecarga = true, ultimaRecarga = pendiente) }
        repository.recargar(token, servicio.id, monto, state.phone) { code, json ->
            val ok = code in 200..299
            _uiState.update {
                it.copy(
                    snackbarMessage = if (ok) json.optString("mensaje", "Recarga enviada") else json.optString("error", "Error de red en recarga"),
                    snackbarSuccess = ok,
                    ultimaRecarga = (it.ultimaRecarga ?: pendiente).copy(
                        estado = if (ok) "ok" else "fallo",
                        mensaje = if (ok) json.optString("mensaje", "Recarga realizada") else json.optString("error", "Recarga fallida"),
                        pendiente = false
                    )
                )
            }
            refreshData { _uiState.update { ui -> ui.copy(processingRecarga = false) } }
        }
    }

    fun refreshData(onComplete: (() -> Unit)? = null) {
        val token = _uiState.value.token ?: return
        if (isRefreshing) {
            onComplete?.invoke()
            return
        }
        isRefreshing = true
        fun finish() {
            isRefreshing = false
            onComplete?.invoke()
        }
        repository.me(token) { c1, me ->
            if (c1 !in 200..299) {
                _uiState.update { it.copy(snackbarMessage = me.optString("error", "No se pudo cargar perfil"), snackbarSuccess = false) }
                finish()
                return@me
            }
            _uiState.update {
                it.copy(
                    welcome = "Hola, ${me.optString("usuario", "cliente")}",
                    saldo = me.optDouble("saldo", 0.0)
                )
            }
            repository.servicios(token) { c2, srv ->
                val list = if (c2 in 200..299 && srv.length() > 0) {
                    (0 until srv.length()).map { i ->
                        val s = srv.getJSONObject(i)
                        Servicio(
                            id = s.optString("id"),
                            nombre = s.optString("nombre", "Operador"),
                            disponible = s.optBoolean("disponible", true),
                            montos = (0 until (s.optJSONArray("montos")?.length() ?: 0)).map { j -> s.optJSONArray("montos")!!.optDouble(j) }
                        )
                    }
                } else emptyList()
                _uiState.update { it.copy(servicios = list, selectedServicio = it.selectedServicio ?: list.firstOrNull(), selectedMonto = it.selectedMonto ?: list.firstOrNull()?.montos?.firstOrNull()) }
            }
            repository.historial(token) { c3, hist ->
                if (c3 !in 200..299) {
                    finish()
                    return@historial
                }
                val movs = (0 until hist.length()).map { i ->
                    val h = hist.getJSONObject(i)
                    Movimiento(
                        servicio = h.optString("servicio"),
                        monto = h.optDouble("monto", 0.0),
                        referencia = h.optString("referencia"),
                        fecha = h.optString("fecha"),
                        estado = h.optString("estado"),
                        mensaje = h.optString("mensaje", "")
                    )
                }
                _uiState.update {
                    it.copy(
                        movimientos = movs,
                        ultimaRecarga = movs.firstOrNull()?.let { last ->
                            UltimaRecarga(
                                servicio = last.servicio,
                                monto = last.monto,
                                referencia = last.referencia,
                                fechaLocal = LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")),
                                estado = last.estado,
                                mensaje = last.mensaje.ifBlank { "Estado actualizado desde servidor" },
                                pendiente = false
                            )
                        } ?: it.ultimaRecarga
                    )
                }
                finish()
            }
        }
    }

    private fun checkServer() {
        repository.checkServer { ok, text -> _uiState.update { it.copy(serverOk = ok, serverText = text) } }
    }

    private fun startAutoRefresh() {
        viewModelScope.launch {
            while (true) {
                delay(10_000)
                if (_uiState.value.isLoggedIn && !isRefreshing) {
                    refreshData()
                }
            }
        }
    }
}

enum class ClientScreen(val route: String) { Home("home"), Historial("historial") }

@Composable
fun ClientApp(state: ClientUiState, viewModel: ClientViewModel) {
    if (!state.isLoggedIn) {
        LoginScreen(state, viewModel)
    } else {
        val navController = rememberNavController()
        val backStack by navController.currentBackStackEntryAsState()
        val route = backStack?.destination?.route
        Scaffold(bottomBar = {
            NavigationBar {
                NavigationBarItem(
                    selected = route == ClientScreen.Home.route,
                    onClick = { navController.navigate(ClientScreen.Home.route) },
                    icon = { Icon(Icons.Default.AccountCircle, null) },
                    label = { Text("Home") }
                )
                NavigationBarItem(
                    selected = route == ClientScreen.Historial.route,
                    onClick = { navController.navigate(ClientScreen.Historial.route) },
                    icon = { Icon(Icons.Default.History, null) },
                    label = { Text("Historial") }
                )
            }
        }) { padding ->
            NavHost(navController = navController, startDestination = ClientScreen.Home.route) {
                composable(ClientScreen.Home.route) { HomeScreen(state, viewModel, padding) }
                composable(ClientScreen.Historial.route) { HistoryScreen(state, padding) }
            }
        }
    }
}

@Composable
private fun LoginScreen(state: ClientUiState, viewModel: ClientViewModel) {
    Column(modifier = Modifier.fillMaxSize().padding(20.dp), verticalArrangement = Arrangement.Center) {
        Icon(Icons.Default.AccountCircle, contentDescription = null, modifier = Modifier.size(72.dp).align(Alignment.CenterHorizontally), tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.height(16.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(10.dp).clip(CircleShape).background(if (state.serverOk) Color(0xFF4CAF50) else Color(0xFFF44336)))
            Spacer(Modifier.width(8.dp))
            Text(state.serverText)
        }
        Spacer(Modifier.height(16.dp))
        OutlinedTextField(value = state.user, onValueChange = viewModel::updateUser, label = { Text("Usuario") }, leadingIcon = { Icon(Icons.Default.AccountCircle, null) }, modifier = Modifier.fillMaxWidth())
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(value = state.pass, onValueChange = viewModel::updatePass, label = { Text("Contraseña") }, visualTransformation = PasswordVisualTransformation(), leadingIcon = { Icon(Icons.Default.Lock, null) }, modifier = Modifier.fillMaxWidth())
        Spacer(Modifier.height(12.dp))
        Button(onClick = viewModel::login, enabled = !state.loginLoading, modifier = Modifier.fillMaxWidth()) {
            if (state.loginLoading) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(8.dp))
            }
            Text("Entrar")
        }
        if (state.loginMessage.isNotBlank()) Text(state.loginMessage, color = MaterialTheme.colorScheme.error)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HomeScreen(state: ClientUiState, viewModel: ClientViewModel, padding: PaddingValues) {
    val snackbarHostState = remember { SnackbarHostState() }
    var showOperators by remember { mutableStateOf(false) }
    LaunchedEffect(state.snackbarMessage) {
        state.snackbarMessage?.let {
            snackbarHostState.showSnackbar(it)
            viewModel.clearSnackbar()
        }
    }

    Scaffold(snackbarHost = { SnackbarHost(snackbarHostState) }) { inner ->
        Column(modifier = Modifier.fillMaxSize().padding(padding).padding(inner).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Surface(shape = RoundedCornerShape(14.dp), tonalElevation = 5.dp, modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(14.dp)) {
                    Text(state.welcome)
                    Text("Saldo: $${"%.2f".format(state.saldo)}", style = MaterialTheme.typography.headlineMedium, color = MaterialTheme.colorScheme.primary)
                }
            }
            Button(onClick = { showOperators = true }, enabled = !state.processingRecarga, modifier = Modifier.fillMaxWidth()) { Text("Seleccionar operador") }
            state.ultimaRecarga?.let { last ->
                Surface(shape = RoundedCornerShape(12.dp), tonalElevation = 3.dp, modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp)) {
                        Text("Última recarga", style = MaterialTheme.typography.titleMedium)
                        Text("Operador: ${last.servicio}")
                        Text("Monto: ${last.monto}")
                        Text("Número: ${last.referencia}")
                        Text("Hora local: ${last.fechaLocal}")
                        AssistChip(
                            onClick = {},
                            label = { Text(if (last.pendiente) "procesando" else last.estado) },
                            enabled = false
                        )
                        if (last.mensaje.isNotBlank()) Text(last.mensaje)
                    }
                }
            }
            val montos = state.selectedServicio?.montos ?: emptyList()
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                montos.forEach { monto ->
                    FilterChip(selected = state.selectedMonto == monto, onClick = { viewModel.selectMonto(monto) }, label = { Text(monto.toInt().toString()) })
                }
            }
            OutlinedTextField(
                value = state.phone,
                onValueChange = viewModel::updatePhone,
                label = { Text("Teléfono") },
                leadingIcon = { Icon(Icons.Default.Phone, null) },
                supportingText = { Text(if (state.phoneValid) "Número válido" else "Debe tener 10 dígitos") },
                isError = state.phone.isNotEmpty() && !state.phoneValid,
                modifier = Modifier.fillMaxWidth(),
                enabled = !state.processingRecarga
            )
            Button(onClick = viewModel::recargar, enabled = !state.processingRecarga && state.selectedServicio != null, modifier = Modifier.fillMaxWidth()) {
                if (state.processingRecarga) CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                else Text("Recargar")
            }
            TextButton(onClick = viewModel::refreshData, enabled = !state.processingRecarga) { Text("Actualizar") }
            TextButton(onClick = viewModel::logout, enabled = !state.processingRecarga) { Text("Salir") }
        }
        if (showOperators) {
            ModalBottomSheet(onDismissRequest = { showOperators = false }, dragHandle = { BottomSheetDefaults.DragHandle() }) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    state.servicios.forEach { srv ->
                        AssistChip(onClick = { viewModel.selectServicio(srv); showOperators = false }, label = { Text(srv.nombre) }, leadingIcon = { Icon(Icons.Default.Phone, null) })
                    }
                }
            }
        }
        if (state.processingRecarga) {
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)), contentAlignment = Alignment.Center) {
                Surface(shape = RoundedCornerShape(12.dp)) {
                    Row(Modifier.padding(18.dp), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(10.dp))
                        Text("Procesando...")
                    }
                }
            }
        }
    }
}

@Composable
private fun HistoryScreen(state: ClientUiState, padding: PaddingValues) {
    if (state.movimientos.isEmpty()) {
        Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.Default.Warning, null)
                Text("Sin movimientos aún")
            }
        }
    } else {
        LazyColumn(Modifier.fillMaxSize().padding(padding).padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(state.movimientos) { m ->
                Surface(shape = RoundedCornerShape(12.dp), tonalElevation = 3.dp, modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp)) {
                        Text(m.servicio)
                        Text("Monto: ${m.monto}")
                        Text("Número: ${m.referencia}")
                        Text("Fecha: ${m.fecha}")
                        AssistChip(onClick = {}, label = { Text(m.estado) }, enabled = false)
                    }
                }
            }
        }
    }
}

@Composable
fun ClientTheme(content: @Composable () -> Unit) {
    val fontFamily = FontFamily.SansSerif
    MaterialTheme(
        colorScheme = androidx.compose.material3.darkColorScheme(
            primary = Color(0xFFB388FF),
            secondary = Color(0xFF7C4DFF),
            tertiary = Color(0xFFD1C4E9)
        ),
        typography = androidx.compose.material3.Typography().run {
            copy(bodyLarge = bodyLarge.copy(fontFamily = fontFamily), titleLarge = titleLarge.copy(fontFamily = fontFamily), headlineMedium = headlineMedium.copy(fontFamily = fontFamily))
        },
        content = content
    )
}
