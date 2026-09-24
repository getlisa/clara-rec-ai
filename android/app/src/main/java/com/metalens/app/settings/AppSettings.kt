package com.metalens.app.settings

import android.content.Context
import com.meta.wearable.dat.camera.types.VideoQuality
import com.metalens.app.BuildConfig
import com.metalens.app.R
import com.metalens.app.conversation.OpenAIRealtimeClient

object AppSettings {
    private const val PREFS_NAME = "meta_lens_ai_settings"
    private const val KEY_OPENAI_API_KEY = "openai_api_key"
    private const val KEY_OPENAI_MODEL = "openai_model"
    private const val KEY_CAMERA_VIDEO_QUALITY = "camera_video_quality"
    private const val KEY_PICTURE_ANALYSIS_SYSTEM_INSTRUCTIONS = "picture_analysis_system_instructions_override"
    private const val KEY_CONVERSATION_SYSTEM_INSTRUCTIONS = "conversation_system_instructions_override"
    private const val KEY_AUTHOR_ID = "author_id"
    private const val KEY_AUTHOR_NAME = "author_name"

    /**
     * Stable per-install identifier for whoever is using this phone.
     *
     * The app has no accounts, so uploads are attributed to this id. It is generated once, on
     * first read, and then kept for the lifetime of the install.
     */
    fun getAuthorId(context: Context): String {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.getString(KEY_AUTHOR_ID, null)?.takeIf { it.isNotBlank() }?.let { return it }

        val generated = java.util.UUID.randomUUID().toString().replace("-", "").take(8)
        prefs.edit().putString(KEY_AUTHOR_ID, generated).apply()
        return generated
    }

    /** Optional human-readable label for the author. Blank until the user sets one. */
    fun getAuthorName(context: Context): String {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getString(KEY_AUTHOR_NAME, null)?.trim().orEmpty()
    }

    fun setAuthorName(context: Context, name: String) {
        val normalized = name.trim()
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (normalized.isBlank()) {
            prefs.edit().remove(KEY_AUTHOR_NAME).apply()
        } else {
            prefs.edit().putString(KEY_AUTHOR_NAME, normalized).apply()
        }
    }

    fun getOpenAiApiKey(context: Context): String {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val fromPrefs = prefs.getString(KEY_OPENAI_API_KEY, null)
        if (!fromPrefs.isNullOrBlank()) return fromPrefs
        return BuildConfig.OPENAI_API_KEY
    }

    fun setOpenAiApiKey(context: Context, apiKey: String) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putString(KEY_OPENAI_API_KEY, apiKey.trim()).apply()
    }

    fun getOpenAiModel(context: Context): String {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val fromPrefs = prefs.getString(KEY_OPENAI_MODEL, null)
        if (!fromPrefs.isNullOrBlank()) return fromPrefs
        val fromBuild = BuildConfig.OPENAI_MODEL
        if (fromBuild.isNotBlank()) return fromBuild
        return OpenAIRealtimeClient.DEFAULT_MODEL
    }

    fun setOpenAiModel(context: Context, model: String) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putString(KEY_OPENAI_MODEL, model.trim()).apply()
    }

    fun getCameraVideoQuality(context: Context): VideoQuality {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_CAMERA_VIDEO_QUALITY, null)?.trim()?.uppercase()
        return when (raw) {
            "LOW" -> VideoQuality.LOW
            "HIGH" -> VideoQuality.HIGH
            "MEDIUM", null, "" -> VideoQuality.MEDIUM
            else -> VideoQuality.MEDIUM
        }
    }

    fun setCameraVideoQuality(context: Context, quality: VideoQuality) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putString(KEY_CAMERA_VIDEO_QUALITY, quality.name).apply()
    }

    fun getPictureAnalysisSystemInstructions(context: Context): String {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val fromPrefs = prefs.getString(KEY_PICTURE_ANALYSIS_SYSTEM_INSTRUCTIONS, null)?.trim()
        if (!fromPrefs.isNullOrBlank()) return fromPrefs
        return context.getString(R.string.picture_analysis_system_instructions).trim()
    }

    fun setPictureAnalysisSystemInstructions(context: Context, instructions: String) {
        val normalized = instructions.trim()
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (normalized.isBlank()) {
            prefs.edit().remove(KEY_PICTURE_ANALYSIS_SYSTEM_INSTRUCTIONS).apply()
        } else {
            prefs.edit().putString(KEY_PICTURE_ANALYSIS_SYSTEM_INSTRUCTIONS, normalized).apply()
        }
    }

    fun resetPictureAnalysisSystemInstructions(context: Context) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().remove(KEY_PICTURE_ANALYSIS_SYSTEM_INSTRUCTIONS).apply()
    }

    fun getConversationSystemInstructions(context: Context): String {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val fromPrefs = prefs.getString(KEY_CONVERSATION_SYSTEM_INSTRUCTIONS, null)?.trim()
        if (!fromPrefs.isNullOrBlank()) return fromPrefs
        return context.getString(R.string.conversation_system_instructions).trim()
    }

    fun setConversationSystemInstructions(context: Context, instructions: String) {
        val normalized = instructions.trim()
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (normalized.isBlank()) {
            prefs.edit().remove(KEY_CONVERSATION_SYSTEM_INSTRUCTIONS).apply()
        } else {
            prefs.edit().putString(KEY_CONVERSATION_SYSTEM_INSTRUCTIONS, normalized).apply()
        }
    }

    fun resetConversationSystemInstructions(context: Context) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().remove(KEY_CONVERSATION_SYSTEM_INSTRUCTIONS).apply()
    }
}

