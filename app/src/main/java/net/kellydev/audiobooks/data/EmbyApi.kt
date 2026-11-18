package net.kellydev.audiobooks.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

@Serializable
data class UserDto(val Id: String = "", val Name: String = "")

@Serializable
data class AuthResult(val AccessToken: String = "", val User: UserDto = UserDto())

@Serializable
data class UserDataDto(
    val PlaybackPositionTicks: Long = 0,
    val PlayedPercentage: Double? = null,
    val IsFavorite: Boolean = false,
    val Played: Boolean = false,
)

@Serializable
data class ChapterDto(
    val StartPositionTicks: Long = 0,
    val Name: String = "",
)

@Serializable
data class EmbyItem(
    val Id: String = "",
    val Name: String = "",
    val Type: String = "",
    val RunTimeTicks: Long? = null,
    val AlbumArtist: String? = null,
    val Artists: List<String> = emptyList(),
    val ImageTags: Map<String, String> = emptyMap(),
    val UserData: UserDataDto? = null,
    val Chapters: List<ChapterDto> = emptyList(),
) {
    val author: String
        get() = AlbumArtist ?: Artists.firstOrNull() ?: ""

    val hasPrimaryImage: Boolean get() = ImageTags.containsKey("Primary")
}

@Serializable
data class ItemsResponse(val Items: List<EmbyItem> = emptyList(), val TotalRecordCount: Int = 0)

@Serializable
data class MediaSourceDto(
    val Id: String = "",
    val Name: String = "",
    val RunTimeTicks: Long? = null,
    val Container: String? = null,
    val DirectStreamUrl: String? = null,
    val TranscodingUrl: String? = null,
)

@Serializable
data class PlaybackInfoResponse(
    val MediaSources: List<MediaSourceDto> = emptyList(),
    val PlaySessionId: String = "",
)

/**
 * Minimal Emby API client covering exactly what this app needs:
 * sign-in, the resume list, the favorites list, item details (chapters),
 * playback info (stream URLs), and playback progress reporting so the
 * position stays synced with the server.
 */
class EmbyApi(
    val server: String,
    private val deviceId: String,
    var token: String = "",
    var userId: String = "",
) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val http = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    private val base: String = server.trim().trimEnd('/')

    private fun authHeaderValue(): String =
        "MediaBrowser Client=\"Audiobooks for Emby\", Device=\"Android\", DeviceId=\"$deviceId\", Version=\"0.1.0\""

    private fun Request.Builder.common(): Request.Builder {
        header("X-Emby-Authorization", authHeaderValue())
        if (token.isNotEmpty()) header("X-Emby-Token", token)
        return this
    }

    private suspend fun execute(request: Request): String = withContext(Dispatchers.IO) {
        http.newCall(request).execute().use { resp ->
            val body = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) {
                throw IllegalStateException("Emby ${resp.code}: ${body.take(200)}")
            }
            body
        }
    }

    suspend fun authenticate(username: String, password: String): AuthResult {
        val payload = json.encodeToString(mapOf("Username" to username, "Pw" to password))
        val request = Request.Builder()
            .url("$base/Users/AuthenticateByName")
            .common()
            .post(payload.toRequestBody("application/json".toMediaType()))
            .build()
        val result = json.decodeFromString<AuthResult>(execute(request))
        token = result.AccessToken
        userId = result.User.Id
        return result
    }

    /** Books with a saved position — the "currently playing" shelf. */
    suspend fun resumeItems(): List<EmbyItem> {
        val url = "$base/Users/$userId/Items/Resume?Limit=24&Recursive=true" +
            "&IncludeItemTypes=AudioBook,Audio&MediaTypes=Audio" +
            "&Fields=PrimaryImageAspectRatio&EnableImages=true"
        val request = Request.Builder().url(url).common().get().build()
        return json.decodeFromString<ItemsResponse>(execute(request)).Items
    }

    /** Every audiobook the user has favorited on the server. */
    suspend fun favoriteItems(): List<EmbyItem> {
        val url = "$base/Users/$userId/Items?Recursive=true&Filters=IsFavorite" +
            "&IncludeItemTypes=AudioBook,Audio&MediaTypes=Audio" +
            "&Fields=PrimaryImageAspectRatio&EnableImages=true&SortBy=SortName&SortOrder=Ascending"
        val request = Request.Builder().url(url).common().get().build()
        return json.decodeFromString<ItemsResponse>(execute(request)).Items
    }

    /** Full item details, including the chapter list when the server has one. */
    suspend fun itemDetails(itemId: String): EmbyItem {
        val url = "$base/Users/$userId/Items/$itemId?Fields=Chapters"
        val request = Request.Builder().url(url).common().get().build()
        return json.decodeFromString<EmbyItem>(execute(request))
    }

    suspend fun playbackInfo(itemId: String): PlaybackInfoResponse {
        val url = "$base/Items/$itemId/PlaybackInfo?UserId=$userId"
        val request = Request.Builder().url(url).common()
            .post("{}".toRequestBody("application/json".toMediaType()))
            .build()
        return json.decodeFromString<PlaybackInfoResponse>(execute(request))
    }

    /** Resolve a media source to an absolute, playable URL. */
    fun streamUrl(itemId: String, source: MediaSourceDto): String {
        val rel = source.DirectStreamUrl ?: source.TranscodingUrl
        if (rel != null) {
            return if (rel.startsWith("http")) rel else base + rel
        }
        val container = source.Container ?: "mp3"
        return "$base/Audio/$itemId/stream.$container?Static=true&api_key=$token"
    }

    fun imageUrl(itemId: String): String =
        "$base/Items/$itemId/Images/Primary?api_key=$token"

    // ---- Playback session reporting: this is what keeps the position
    // ---- synced in Emby (and therefore in every other Emby client).

    private suspend fun report(path: String, itemId: String, playSessionId: String,
                               positionTicks: Long, isPaused: Boolean) {
        // Built raw: PositionTicks/CanSeek/IsPaused must be real JSON types.
        val raw = buildString {
            append("{\"ItemId\":\"").append(itemId).append("\",")
            append("\"PlaySessionId\":\"").append(playSessionId).append("\",")
            append("\"PositionTicks\":").append(positionTicks).append(',')
            append("\"PlayMethod\":\"DirectStream\",")
            append("\"CanSeek\":true,")
            append("\"IsPaused\":").append(isPaused).append('}')
        }
        val request = Request.Builder().url("$base$path").common()
            .post(raw.toRequestBody("application/json".toMediaType()))
            .build()
        runCatching { execute(request) } // reporting must never break playback
    }

    suspend fun reportPlaying(itemId: String, playSessionId: String, positionTicks: Long) =
        report("/Sessions/Playing", itemId, playSessionId, positionTicks, isPaused = false)

    suspend fun reportProgress(itemId: String, playSessionId: String, positionTicks: Long, isPaused: Boolean) =
        report("/Sessions/Playing/Progress", itemId, playSessionId, positionTicks, isPaused)

    suspend fun reportStopped(itemId: String, playSessionId: String, positionTicks: Long) =
        report("/Sessions/Playing/Stopped", itemId, playSessionId, positionTicks, isPaused = true)

    companion object {
        const val TICKS_PER_MS = 10_000L
        fun msToTicks(ms: Long): Long = ms * TICKS_PER_MS
        fun ticksToMs(ticks: Long): Long = ticks / TICKS_PER_MS
    }
}
