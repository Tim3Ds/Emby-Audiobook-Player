package net.kellydev.audiobooks.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import net.kellydev.audiobooks.data.EmbyApi
import net.kellydev.audiobooks.data.SessionStore

@Composable
fun LoginScreen(store: SessionStore, onSignedIn: (EmbyApi) -> Unit) {
    var server by remember { mutableStateOf(store.server) }
    var username by remember { mutableStateOf(store.username) }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Text("Audiobooks for Emby", style = MaterialTheme.typography.headlineMedium)
        Spacer(Modifier.height(8.dp))
        Text(
            "Sign in to your Emby server. This app shows only your favorite " +
                "audiobooks and the book you're in the middle of.",
            style = MaterialTheme.typography.bodyMedium,
        )
        Spacer(Modifier.height(24.dp))
        OutlinedTextField(
            value = server, onValueChange = { server = it },
            label = { Text("Server") }, singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(12.dp))
        OutlinedTextField(
            value = username, onValueChange = { username = it },
            label = { Text("Username") }, singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(12.dp))
        OutlinedTextField(
            value = password, onValueChange = { password = it },
            label = { Text("Password") }, singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            modifier = Modifier.fillMaxWidth(),
        )
        if (error != null) {
            Spacer(Modifier.height(12.dp))
            Text(error!!, color = MaterialTheme.colorScheme.error)
        }
        Spacer(Modifier.height(20.dp))
        Button(
            enabled = !busy && username.isNotBlank(),
            onClick = {
                busy = true
                error = null
                scope.launch {
                    try {
                        val api = EmbyApi(server, store.deviceId)
                        val result = api.authenticate(username.trim(), password)
                        store.server = server.trim()
                        store.username = username.trim()
                        store.userId = result.User.Id
                        store.token = result.AccessToken
                        onSignedIn(api)
                    } catch (e: Exception) {
                        error = "Sign-in failed: ${e.message ?: "unknown error"}"
                    } finally {
                        busy = false
                    }
                }
            },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(if (busy) "Signing in…" else "Sign in")
        }
        Spacer(Modifier.height(12.dp))
        Text(
            "Your password goes only to your Emby server. The app keeps a " +
                "sign-in token on this device so you don't have to repeat this.",
            style = MaterialTheme.typography.bodySmall,
        )
    }
}
