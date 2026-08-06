package com.openminis.app.provider

import com.openminis.app.BuildConfig
import okhttp3.Request

/** Applies the branded app identity to requests without a protocol-specific UA. */
fun Request.Builder.applyDefaultUserAgent(): Request.Builder {
    header("User-Agent", MinisUserAgent.DEFAULT)
    return this
}

/**
 * Branded User-Agent used by Minis requests that do not require a specific
 * OAuth client identity.
 */
object MinisUserAgent {
    val DEFAULT: String by lazy {
        val release = android.os.Build.VERSION.RELEASE ?: "unknown"
        val model = (android.os.Build.MODEL ?: "unknown").trim().ifEmpty { "unknown" }
        "Minis/${BuildConfig.VERSION_NAME} (Android $release; $model)"
    }
}
