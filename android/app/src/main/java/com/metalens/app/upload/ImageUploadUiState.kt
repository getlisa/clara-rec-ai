package com.metalens.app.upload

sealed interface UploadStatus {
    /** Nothing captured yet. */
    data object Idle : UploadStatus

    /** No bucket/credentials configured — uploading is simply off. */
    data object NotConfigured : UploadStatus

    data object Uploading : UploadStatus

    data class Uploaded(val uri: String) : UploadStatus

    data class Failed(val message: String) : UploadStatus
}

data class ImageUploadUiState(
    val status: UploadStatus = UploadStatus.Idle,
    val authorPrefix: String = "",
) {
    val isUploading: Boolean get() = status is UploadStatus.Uploading
    val canRetry: Boolean get() = status is UploadStatus.Failed
}
