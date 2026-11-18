package net.kellydev.audiobooks.data

import android.content.Context
import java.util.UUID

/**
 * Persists the sign-in session and player preferences in app-private
 * SharedPreferences. The token stays on this device only.
 */
class SessionStore(context: Context) {
    private val prefs = context.getSharedPreferences("session", Context.MODE_PRIVATE)

    var server: String
        get() = prefs.getString("server", "https://emby.kellydev.net") ?: "https://emby.kellydev.net"
        set(value) = prefs.edit().putString("server", value).apply()

    var username: String
        get() = prefs.getString("username", "") ?: ""
        set(value) = prefs.edit().putString("username", value).apply()

    var userId: String
        get() = prefs.getString("userId", "") ?: ""
        set(value) = prefs.edit().putString("userId", value).apply()

    var token: String
        get() = prefs.getString("token", "") ?: ""
        set(value) = prefs.edit().putString("token", value).apply()

    val deviceId: String
        get() {
            val existing = prefs.getString("deviceId", null)
            if (existing != null) return existing
            val created = UUID.randomUUID().toString()
            prefs.edit().putString("deviceId", created).apply()
            return created
        }

    var skipForwardSec: Int
        get() = prefs.getInt("skipForwardSec", 30)
        set(value) = prefs.edit().putInt("skipForwardSec", value).apply()

    var skipBackSec: Int
        get() = prefs.getInt("skipBackSec", 15)
        set(value) = prefs.edit().putInt("skipBackSec", value).apply()

    val isSignedIn: Boolean get() = token.isNotEmpty() && userId.isNotEmpty()

    fun signOut() {
        prefs.edit().remove("token").remove("userId").apply()
    }
}
