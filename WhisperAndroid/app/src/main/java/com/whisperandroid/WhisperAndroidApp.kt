package com.whisperandroid

import android.app.Application
import android.util.Log
import com.runanywhere.sdk.core.onnx.ONNX
import com.runanywhere.sdk.public.RunAnywhere
import com.runanywhere.sdk.public.SDKEnvironment
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class WhisperAndroidApp : Application() {
    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    override fun onCreate() {
        super.onCreate()
        appScope.launch {
            initializeRunAnywhere()
        }
    }

    private suspend fun initializeRunAnywhere() {
        try {
            if (!RunAnywhere.isInitialized) {
                RunAnywhere.initialize(environment = SDKEnvironment.DEVELOPMENT)
            }
            ONNX.register(priority = 100)
            try {
                RunAnywhere.completeServicesInitialization()
            } catch (e: Exception) {
                Log.w(TAG, "RunAnywhere services init failed, continuing in local mode: ${e.message}")
            }
            runAnywhereInit.complete(Result.success(Unit))
            Log.i(TAG, "RunAnywhere initialized")
        } catch (t: Throwable) {
            if (!runAnywhereInit.isCompleted) {
                runAnywhereInit.complete(Result.failure(t))
            }
            Log.e(TAG, "RunAnywhere init failed: ${t.message}", t)
        }
    }

    companion object {
        private const val TAG = "WhisperAndroidApp"
        private val runAnywhereInit = CompletableDeferred<Result<Unit>>()

        suspend fun awaitRunAnywhereInit(): Result<Unit> {
            return runAnywhereInit.await()
        }
    }
}
