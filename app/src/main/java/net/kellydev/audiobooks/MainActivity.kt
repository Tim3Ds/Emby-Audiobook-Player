package net.kellydev.audiobooks

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.media3.session.MediaController
import com.google.common.util.concurrent.FutureCallback
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.launch
import net.kellydev.audiobooks.data.EmbyApi
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

    // Connect a MediaController to the playback service.
    var controller by remember { mutableStateOf<MediaController?>(null) }
    DisposableEffect(Unit) {
        val future: ListenableFuture<MediaController> = MediaController
            .Builder(context, PlaybackService.sessionToken(context))
            .buildAsync()
        Futures.addCallback(
            future,
            object : FutureCallback<MediaController> {
                override fun onSuccess(c: MediaController) {
                    controller = c
                }

                override fun onFailure(t: Throwable) {
                    // Playback unavailable; library still browsable.
                }
            },
            ContextCompat.getMainExecutor(context),
        )
        onDispose {
            controller?.release()
            MediaController.releaseFuture(future)
        }
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
                    onOpenBook = { item ->
                        val c = controller
                        if (c != null && !openingBook) {
                            openingBook = true
                            scope.launch {
                                try {
                                    val session = startBook(currentApi, c, item)
                                    screen = Screen.Player(session)
                                } catch (e: Exception) {
                                    // Stay in the library; a future version surfaces this.
                                } finally {
                                    openingBook = false
                                }
                            }
                        }
                    },
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
