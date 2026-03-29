package com.recargas.admin

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import com.recargas.admin.databinding.ActivityMainBinding

class MainActivity : AppCompatActivity() {
    private lateinit var binding: ActivityMainBinding

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.inputApiBase.setText(BuildConfig.API_BASE_URL)
        binding.inputAppKey.setText(BuildConfig.APP_ADMIN_KEY)
        binding.inputUser.setText(BuildConfig.DEFAULT_ADMIN_USER)
        binding.inputPass.setText(BuildConfig.DEFAULT_ADMIN_PASSWORD)

        binding.btnSave.setOnClickListener {
            binding.txtStatus.text = "Datos cargados. Implementar login API en siguiente etapa."
        }
    }
}
