package net.kellydev.audiobooks.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Logout
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import net.kellydev.audiobooks.data.EmbyApi
import net.kellydev.audiobooks.data.EmbyItem

@Composable
fun LibraryScreen(
    api: EmbyApi,
    onOpenBook: (EmbyItem) -> Unit,
    onSignOut: () -> Unit,
) {
    var resume by remember { mutableStateOf<List<EmbyItem>>(emptyList()) }
    var favorites by remember { mutableStateOf<List<EmbyItem>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var reloadKey by remember { mutableStateOf(0) }

    LaunchedEffect(reloadKey) {
        loading = true
        error = null
        try {
            resume = api.resumeItems()
            favorites = api.favoriteItems()
        } catch (e: Exception) {
            error = "Couldn't load your books: ${e.message ?: "unknown error"}"
        } finally {
            loading = false
        }
    }

    Column(Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "Your Books",
                style = MaterialTheme.typography.headlineSmall,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = onSignOut) {
                Icon(Icons.Filled.Logout, contentDescription = "Sign out")
            }
        }

        when {
            loading -> Text("Loading…", Modifier.padding(16.dp))
            error != null -> Column(Modifier.padding(16.dp)) {
                Text(error!!, color = MaterialTheme.colorScheme.error)
                Spacer(Modifier.height(12.dp))
                Button(onClick = { reloadKey++ }) { Text("Retry") }
            }
            else -> LazyColumn(Modifier.fillMaxSize()) {
                item {
                    Text(
                        "Continue Listening",
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                }
                if (resume.isEmpty()) {
                    item {
                        Text(
                            "Nothing in progress. Start a book and it will wait for you here.",
                            style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                        )
                    }
                }
                items(resume) { item -> BookRow(api, item) { onOpenBook(item) } }

                item {
                    Spacer(Modifier.height(16.dp))
                    Text(
                        "Favorites",
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                }
                if (favorites.isEmpty()) {
                    item {
                        Text(
                            "No favorites yet. Favorite a book in Emby and it shows up here.",
                            style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                        )
                    }
                }
                items(favorites) { item -> BookRow(api, item) { onOpenBook(item) } }
                item { Spacer(Modifier.height(24.dp)) }
            }
        }
    }
}

@Composable
private fun BookRow(api: EmbyApi, item: EmbyItem, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (item.hasPrimaryImage) {
            AsyncImage(
                model = api.imageUrl(item.Id),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(56.dp)
                    .clip(MaterialTheme.shapes.small),
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(item.Name, style = MaterialTheme.typography.bodyLarge, maxLines = 2)
            if (item.author.isNotBlank()) {
                Text(item.author, style = MaterialTheme.typography.bodyMedium)
            }
            val pct = item.UserData?.PlayedPercentage
            val progress: Float? = when {
                pct != null -> (pct / 100.0).toFloat()
                item.UserData != null && item.RunTimeTicks != null && item.RunTimeTicks > 0 ->
                    (item.UserData.PlaybackPositionTicks.toDouble() / item.RunTimeTicks.toDouble()).toFloat()
                else -> null
            }
            if (progress != null) {
                Spacer(Modifier.height(6.dp))
                LinearProgressIndicator(
                    progress = { progress.coerceIn(0f, 1f) },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}
