package net.kellydev.audiobooks

import android.content.Context
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter

/**
 * Last-resort crash capture for a sideloaded app with no Play Console:
 * records the stack trace of an uncaught exception (or an explicitly
 * caught startup failure) to a file, so the next launch can show it
 * on screen instead of the app just dying silently.
 */
object CrashLog {
    private const val FILE = "last-crash.txt"

    fun install(context: Context) {
        val appContext = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        if (previous is Marker) return
        Thread.setDefaultUncaughtExceptionHandler(Marker(appContext, previous))
    }

    private class Marker(
        private val appContext: Context,
        private val previous: Thread.UncaughtExceptionHandler?,
    ) : Thread.UncaughtExceptionHandler {
        override fun uncaughtException(thread: Thread, error: Throwable) {
            record(appContext, error)
            previous?.uncaughtException(thread, error)
        }
    }

    fun record(context: Context, error: Throwable) {
        try {
            val sw = StringWriter()
            error.printStackTrace(PrintWriter(sw))
            File(context.filesDir, FILE).writeText(sw.toString())
        } catch (_: Throwable) {
            // Never let the crash reporter crash.
        }
    }

    fun read(context: Context): String? = try {
        val f = File(context.filesDir, FILE)
        if (f.exists()) f.readText().takeIf { it.isNotBlank() } else null
    } catch (_: Throwable) {
        null
    }

    fun clear(context: Context) {
        try {
            File(context.filesDir, FILE).delete()
        } catch (_: Throwable) {
        }
    }
}
