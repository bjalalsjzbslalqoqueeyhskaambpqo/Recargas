package com.recargas.client

import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

class ApiClient {
    fun getJson(path: String, token: String?, onDone: (Int, JSONObject) -> Unit) {
        request(path, "GET", null, token = token) { code, raw -> onDone(code, parseJson(raw)) }
    }

    fun getJsonArray(path: String, token: String?, onDone: (Int, JSONArray) -> Unit) {
        request(path, "GET", null, token = token) { code, raw -> onDone(code, parseArray(raw)) }
    }

    fun postJson(
        path: String,
        body: JSONObject,
        token: String? = null,
        readTimeoutMs: Int = 8000,
        onDone: (Int, JSONObject) -> Unit
    ) {
        request(path, "POST", body.toString(), token = token, readTimeoutMs = readTimeoutMs) { code, raw ->
            onDone(code, parseJson(raw))
        }
    }

    fun request(
        path: String,
        method: String,
        body: String?,
        token: String? = null,
        connectTimeoutMs: Int = 8000,
        readTimeoutMs: Int = 8000,
        onDone: (Int, String) -> Unit
    ) {
        thread {
            try {
                val url = URL("${BuildConfig.API_BASE_URL}$path")
                val conn = url.openConnection() as HttpURLConnection
                conn.requestMethod = method
                conn.setRequestProperty("Content-Type", "application/json")
                conn.setRequestProperty("X-App-Key", BuildConfig.APP_CLIENT_KEY)
                if (token != null) conn.setRequestProperty("Authorization", "Bearer $token")
                conn.connectTimeout = connectTimeoutMs
                conn.readTimeout = readTimeoutMs

                if (body != null) {
                    conn.doOutput = true
                    OutputStreamWriter(conn.outputStream).use { it.write(body) }
                }

                val code = conn.responseCode
                val text = (if (code in 200..299) conn.inputStream else conn.errorStream)
                    .bufferedReader().use(BufferedReader::readText)
                onDone(code, text)
            } catch (e: Exception) {
                onDone(500, "{\"error\":\"${e.message}\"}")
            }
        }
    }

    private fun parseJson(raw: String): JSONObject = try { JSONObject(raw) } catch (_: Exception) { JSONObject() }
    private fun parseArray(raw: String): JSONArray = try { JSONArray(raw) } catch (_: Exception) { JSONArray() }
}
