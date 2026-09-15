package com.metalens.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.metalens.app.R
import com.metalens.app.ui.components.FeatureActionCard

@Composable
fun HomeScreen(
    modifier: Modifier = Modifier,
    isGlassesConnected: Boolean = false,
    isCapturingPhoto: Boolean = false,
    onStartStreaming: () -> Unit = {},
    onPictureAnalysis: () -> Unit = {},
) {
    Column(
        modifier =
            modifier
                .fillMaxSize()
                .padding(PaddingValues(horizontal = 20.dp, vertical = 24.dp)),
        verticalArrangement = Arrangement.Top,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            painter = painterResource(id = R.drawable.smart_glasses_icon),
            contentDescription = stringResource(R.string.home_glasses_icon_description),
            modifier = Modifier.padding(top = 4.dp).size(112.dp),
        )
        Spacer(modifier = Modifier.height(12.dp))
        Text(
            text = stringResource(R.string.home_subtitle),
            style = MaterialTheme.typography.bodyMedium,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(modifier = Modifier.height(20.dp))

        FeatureActionCard(
            title = stringResource(R.string.start_streaming),
            subtitle = stringResource(R.string.start_streaming_subtitle),
            icon = Icons.Filled.Videocam,
            enabled = isGlassesConnected,
            onClick = onStartStreaming,
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(modifier = Modifier.height(12.dp))

        FeatureActionCard(
            title =
                if (isCapturingPhoto) {
                    stringResource(R.string.picture_analysis_capturing)
                } else {
                    stringResource(R.string.picture_analysis)
                },
            subtitle = stringResource(R.string.picture_analysis_subtitle),
            icon = Icons.Filled.CameraAlt,
            enabled = isGlassesConnected && !isCapturingPhoto,
            onClick = onPictureAnalysis,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Preview(showBackground = true)
@Composable
private fun HomeScreenPreview() {
    HomeScreen()
}

