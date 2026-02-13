package com.whisperandroid

import android.content.Context
import java.io.File

object AssetUtils {
    fun assetExists(context: Context, assetPath: String): Boolean {
        return try {
            val children = context.assets.list(assetPath)
            if (children != null && children.isNotEmpty()) {
                true
            } else {
                context.assets.open(assetPath).close()
                true
            }
        } catch (_: Exception) {
            false
        }
    }

    fun copyAssetPathToFileSystem(context: Context, assetPath: String, destination: File): File {
        val children = context.assets.list(assetPath)
        return if (children != null && children.isNotEmpty()) {
            copyAssetDirectory(context, assetPath, destination)
        } else {
            copyAssetFile(context, assetPath, destination)
        }
    }

    private fun copyAssetDirectory(context: Context, assetPath: String, destinationDir: File): File {
        if (!destinationDir.exists()) {
            destinationDir.mkdirs()
        }
        val children = context.assets.list(assetPath).orEmpty()
        for (child in children) {
            val childAssetPath = "$assetPath/$child"
            val childDest = File(destinationDir, child)
            val grandChildren = context.assets.list(childAssetPath)
            if (grandChildren != null && grandChildren.isNotEmpty()) {
                copyAssetDirectory(context, childAssetPath, childDest)
            } else {
                copyAssetFile(context, childAssetPath, childDest)
            }
        }
        return destinationDir
    }

    private fun copyAssetFile(context: Context, assetPath: String, destinationFile: File): File {
        destinationFile.parentFile?.mkdirs()
        context.assets.open(assetPath).use { input ->
            destinationFile.outputStream().use { output ->
                input.copyTo(output)
            }
        }
        return destinationFile
    }
}
