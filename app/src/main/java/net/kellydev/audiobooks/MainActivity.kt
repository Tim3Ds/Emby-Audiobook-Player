package net.kellydev.audiobooks

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.media3.session.MediaController
import com.google.common.util.concurrent.FutureCallback
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.launch
import net.kellydev.audiobooks.data.EmbyApi
import net.kellydev.audiobooks.data.EmbyItem
import net.kellydev.audiobooks.data.SessionStore
import net.kellydev.audiobooks.player.BookSession
import net.kellydev.audiobooks.player.PlaybackService
import net.kellydev.audiobooks.ui.LibraryScreen
import net.kellydev.audiobooks.ui.LoginScreen
import net.kellydev.audiobooks.ui.PlayerScreen
import net.kellydev.audiobooks.ui.startBook

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        CrashLog.install(this)
        if (Build.VERSION.SDK_INT >= 33) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
        setContent {
            MaterialTheme {
                AppRoot()
            }
        }
    }
}

private sealed interface Screen {
    data object Login : Screen
    data object Library : Screen
    data class Player(val session: BookSession) : Screen
}

@Composable
private fun AppRoot() {
    val context = LocalContext.current
    val store = remember { SessionStore(context) }
    val scope = rememberCoroutineScope()

    // If the previous run died, show the recorded trace before anything
    // else runs — this build's startup path stays untouched until the
    // user dismisses it.
    var crash by remember { mutableStateOf(CrashLog.read(context)) }
    if (crash != null) {
        CrashScreen(
            trace = crash!!,
            onDismiss = {
                CrashLog.clear(context)
                crash = null
            },
        )
        return
    }

    var api by remember {
        mutableStateOf(
            if (store.isSignedIn) {
                EmbyApi(store.server, store.deviceId, token = store.token, userId = store.userId)
            } else null
        )
    }
    var screen by remember {
        mutableStateOf<Screen>(if (store.isSignedIn) Screen.Library else Screen.Login)
    }
    var openingBook by remember { mutableStateOf(false) }

    // The MediaController (and with it the playback service) connects
    // lazily, the first time a book is opened — startup never touches
    // the playback stack.
    var controller by remember { mutableStateOf<MediaController?>(null) }
    var controllerFuture by remember { mutableStateOf<ListenableFuture<MediaController>?>(null) }
    var connecting by remember { mutableStateOf(false) }
    var pendingOpen by remember { mutableStateOf<EmbyItem?>(null) }

    DisposableEffect(Unit) {
        onDispose {
            controller?.release()
            controllerFuture?.let { MediaController.releaseFuture(it) }
        }
    }

    fun openBook(item: EmbyItem, c: MediaController) {
        val currentApi = api ?: return
        if (openingBook) return
        openingBook = true
        scope.launch {
            try {
                val session = startBook(currentApi, c, item)
                screen = Screen.Player(session)
            } catch (e: Exception) {
                CrashLog.record(context, e)
            } finally {
                openingBook = false
            }
        }
    }

    fun onOpenBook(item: EmbyItem) {
        val c = controller
        if (c != null) {
            openBook(item, c)
            return
        }
        pendingOpen = item
        if (connecting) return
        connecting = true
        val future = MediaController
            .Builder(context, PlaybackService.sessionToken(context))
            .buildAsync()
        controllerFuture = future
        Futures.addCallback(
            future,
            object : FutureCallback<MediaController> {
                override fun onSuccess(c2: MediaController) {
                    controller = c2
                    connecting = false
                    val pending = pendingOpen
                    pendingOpen = null
                    if (pending != null) openBook(pending, c2)
                }

                override fun onFailure(t: Throwable) {
                    connecting = false
                    pendingOpen = null
                    CrashLog.record(context, t)
                }
            },
            ContextCompat.getMainExecutor(context),
        )
    }

    when (val s = screen) {
        is Screen.Login -> LoginScreen(store) { signedInApi ->
            api = signedInApi
            screen = Screen.Library
        }

        is Screen.Library -> {
            val currentApi = api
            if (currentApi == null) {
                screen = Screen.Login
            } else {
                LibraryScreen(
                    api = currentApi,
                    onOpenBook = { item -> onOpenBook(item) },
                    onSignOut = {
                        controller?.stop()
                        controller?.clearMediaItems()
                        store.signOut()
                        api = null
                        screen = Screen.Login
                    },
                )
            }
        }

        is Screen.Player -> {
            val currentApi = api
            val c = controller
            if (currentApi == null || c == null) {
                screen = Screen.Library
            } else {
                PlayerScreen(
                    api = currentApi,
                    store = store,
                    controller = c,
                    session = s.session,
                    onBack = { screen = Screen.Library },
                )
            }
        }
    }
}

@Composable
private fun CrashScreen(trace: String, onDismiss: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(20.dp),
        verticalArrangement = Arrangement.Top,
    ) {
        Text("The app crashed last time", style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(8.dp))
        Text(
            "Here's the recorded error. A screenshot of this screen is " +
                "enough to pinpoint the fault.",
            style = MaterialTheme.typography.bodyMedium,
        )
        Spacer(Modifier.height(12.dp))
        Column(
            modifier = Modifier.weight(1f).verticalScroll(rememberScrollState()),
        ) {
            Text(trace, fontFamily = FontFamily.Monospace, fontSize = 11.sp)
        }
        Spacer(Modifier.height(12.dp))
        Button(onClick = onDismiss) { Text("Dismiss and continue") }
    }
}
