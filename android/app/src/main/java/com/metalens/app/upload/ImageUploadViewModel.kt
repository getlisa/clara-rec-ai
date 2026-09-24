package com.metalens.app.upload

import android.app.Application
import android.graphics.Bitmap
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Date

/** Drives image uploads to S3, alongside (and independently of) AI analysis. */
class ImageUploadViewModel(
    application: Application,
) : AndroidViewModel(application) {
    private val uploader = S3ImageUploader()

    private val _uiState = MutableStateFlow(ImageUploadUiState())
    val uiState: StateFlow<ImageUploadUiState> = _uiState.asStateFlow()

    private var job: Job? = null

    /**
     * Identity of the bitmap currently uploaded or uploading, so that recomposition or a
     * configuration change doesn't re-send the same capture.
     */
    private var inFlightPhoto: Bitmap? = null

    fun reset() {
        job?.cancel()
        job = null
        inFlightPhoto = null
        _uiState.value = ImageUploadUiState()
    }

    /** Uploads [bitmap] unless that exact capture is already uploaded or in flight. */
    fun uploadIfNeeded(bitmap: Bitmap) {
        if (inFlightPhoto === bitmap && _uiState.value.status !is UploadStatus.Failed) return
        upload(bitmap)
    }

    /** Uploads [bitmap] unconditionally — used by the retry action. */
    fun upload(bitmap: Bitmap) {
        val context = getApplication<Application>().applicationContext
        val config = S3Config.fromBuildConfig()
        val author = AuthorIdentity.current(context)

        if (!config.isConfigured) {
            inFlightPhoto = null
            _uiState.value =
                ImageUploadUiState(
                    status = UploadStatus.NotConfigured,
                    authorPrefix = author.storagePrefix,
                )
            return
        }

        inFlightPhoto = bitmap
        job?.cancel()
        job =
            viewModelScope.launch {
                _uiState.update {
                    it.copy(status = UploadStatus.Uploading, authorPrefix = author.storagePrefix)
                }

                val result =
                    withContext(Dispatchers.IO) {
                        uploader.upload(
                            config = config,
                            author = author,
                            bitmap = bitmap,
                            capturedAt = Date(),
                        )
                    }

                result.fold(
                    onSuccess = { upload ->
                        _uiState.update { it.copy(status = UploadStatus.Uploaded(upload.uri)) }
                    },
                    onFailure = { error ->
                        inFlightPhoto = null
                        _uiState.update {
                            it.copy(
                                status =
                                    UploadStatus.Failed(
                                        error.message
                                            ?: error.javaClass.simpleName
                                            ?: "Upload failed",
                                    ),
                            )
                        }
                    },
                )
            }
    }
}
