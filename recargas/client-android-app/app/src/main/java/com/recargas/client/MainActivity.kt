package com.recargas.client

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.runtime.getValue
import androidx.compose.runtime.collectAsState
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider

class MainActivity : ComponentActivity() {
    private val viewModel by viewModels<ClientViewModel> {
        val prefs = getSharedPreferences("client_prefs", MODE_PRIVATE)
        ClientViewModelFactory(ClientRepository(), prefs)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                viewModel.onAppForeground()
            }
        })
        setContent {
            val state by viewModel.uiState.collectAsState()
            ClientTheme {
                ClientApp(state = state, viewModel = viewModel)
            }
        }
    }
}

class ClientViewModelFactory(
    private val repository: ClientRepository,
    private val prefs: android.content.SharedPreferences
) : ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        @Suppress("UNCHECKED_CAST")
        return ClientViewModel(repository, prefs) as T
    }
}
