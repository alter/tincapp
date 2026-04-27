/*
 * Tinc Mesh VPN: Android client and user interface
 * Copyright (C) 2017-2024 Euxane P. TRAN-GIRARD
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

package org.pacien.tincapp.activities.configure.tools

import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import androidx.activity.result.contract.ActivityResultContracts
import java8.util.concurrent.CompletableFuture
import org.pacien.tincapp.R
import org.pacien.tincapp.commands.Executor.supplyAsyncTask
import org.pacien.tincapp.context.AppPaths
import org.pacien.tincapp.databinding.ConfigureToolsDialogNetworkImportBinding
import org.pacien.tincapp.utils.isParentOf
import org.pacien.tincapp.utils.makePrivate
import java.io.File
import java.io.FileNotFoundException
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream

/**
 * @author euxane
 */
class ImportNetworkToolDialogFragment : ConfigurationToolDialogFragment() {
  companion object {
    private const val MAX_TEXT_SCAN_BYTES = 1L * 1024 * 1024
    private val ARCHIVE_MIME_TYPES = arrayOf(
      "application/zip",
      "application/x-zip-compressed",
      "application/octet-stream"
    )
  }

  private var importDialog: ConfigureToolsDialogNetworkImportBinding? = null
  private var selectedArchive: Uri? = null

  // Registered eagerly as a property so it is available before the
  // fragment reaches STARTED, which is what registerForActivityResult
  // requires.
  private val pickArchiveLauncher =
    registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
      if (uri != null) {
        selectedArchive = uri
        importDialog?.archivePath?.setText(displayNameOf(uri))
      }
    }

  override fun onCreateDialog(savedInstanceState: Bundle?) =
    makeImportDialog().let { newDialog ->
      importDialog = newDialog
      makeDialog(
        newDialog,
        R.string.configure_tools_import_network_title,
        R.string.configure_tools_import_network_action
      ) { dialog ->
        importNetwork(dialog.netName.text.toString(), selectedArchive)
      }
    }

  private fun makeImportDialog() =
    ConfigureToolsDialogNetworkImportBinding.inflate(dialogLayoutInflater)
      .apply { pickAction = this@ImportNetworkToolDialogFragment::pickArchive }

  private fun pickArchive() {
    pickArchiveLauncher.launch(ARCHIVE_MIME_TYPES)
  }

  private fun importNetwork(netName: String, archive: Uri?) {
    if (archive == null) {
      parentActivity.showErrorDialog(R.string.configure_tools_import_network_message_no_archive)
      return
    }

    val effectiveName = netName.ifBlank { stripArchiveExtension(displayNameOf(archive)) }
    if (effectiveName.isBlank()) {
      parentActivity.showErrorDialog(R.string.configure_tools_message_invalid_network_name)
      return
    }

    execAction(
      R.string.configure_tools_import_network_importing,
      validateNetName(effectiveName)
        .thenCompose { ensureNoExistingNetwork(effectiveName) }
        .thenCompose { extractArchive(archive, effectiveName) }
    )
  }

  private fun ensureNoExistingNetwork(netName: String): CompletableFuture<Unit> {
    val target = AppPaths.confDir(netName)
    return if (target.exists())
      CompletableFuture.failedFuture(IllegalStateException(
        getString(R.string.configure_tools_import_network_message_already_exists_format, netName)))
    else
      CompletableFuture.completedFuture(Unit)
  }

  private fun extractArchive(archive: Uri, netName: String): CompletableFuture<Unit> {
    val resolver = parentActivity.contentResolver
    val cacheDir = parentActivity.cacheDir
    val invalidArchiveMsg = getString(R.string.configure_tools_import_network_message_invalid_archive)
    val unsafeArchiveMsg = getString(R.string.configure_tools_import_network_message_unsafe_archive)

    return supplyAsyncTask {
      val target = AppPaths.confDir(netName)
      val staging = File.createTempFile("tincapp_import_", "", cacheDir).apply {
        delete()
        mkdirs()
      }

      try {
        val entryCount = resolver.openInputStream(archive)?.use { input ->
          ZipInputStream(input).use { zip -> unpackInto(zip, staging) }
        } ?: throw FileNotFoundException(invalidArchiveMsg)

        if (entryCount == 0)
          throw IllegalArgumentException(invalidArchiveMsg)

        rejectInterpolation(staging, unsafeArchiveMsg)

        target.parentFile?.mkdirs()
        val source = effectiveRoot(staging)
        if (!source.renameTo(target)) {
          source.copyRecursively(target, overwrite = false)
        }
        target.makePrivate()
      } catch (e: Exception) {
        target.deleteRecursively()
        throw e
      } finally {
        staging.deleteRecursively()
      }
    }
  }

  private fun unpackInto(zip: ZipInputStream, root: File): Int {
    var count = 0
    var entry: ZipEntry? = zip.nextEntry
    while (entry != null) {
      val out = File(root, entry.name)
      if (!root.isParentOf(out, false))
        throw SecurityException("Archive entry escapes target directory: ${entry.name}")

      if (entry.isDirectory) {
        out.mkdirs()
      } else {
        out.parentFile?.mkdirs()
        out.outputStream().use { sink -> zip.copyTo(sink) }
      }
      count++
      zip.closeEntry()
      entry = zip.nextEntry
    }
    return count
  }

  private fun effectiveRoot(staging: File): File {
    val children = staging.listFiles() ?: emptyArray()
    return if (children.size == 1 && children[0].isDirectory) children[0] else staging
  }

  // tinc config files never legitimately contain "${...}" expressions.
  // commons-configuration2 2.3 evaluates such lookups (script, dns, url,
  // etc.) on every getString() call, which would let a malicious archive
  // execute code in the app context. We disable the interpolator on the
  // parser side too, but reject the archive up-front as defense in depth.
  private fun rejectInterpolation(staging: File, errorMessage: String) {
    staging.walkTopDown()
      .filter { it.isFile && it.length() <= MAX_TEXT_SCAN_BYTES }
      .filter { it.extension.equals("conf", ignoreCase = true) || it.name == "invitation-data" }
      .forEach { f ->
        if (f.readText(Charsets.UTF_8).contains("\${"))
          throw SecurityException(errorMessage)
      }
  }

  private fun displayNameOf(uri: Uri): String {
    parentActivity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
      if (cursor.moveToFirst()) {
        val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
        if (idx >= 0) return cursor.getString(idx)
      }
    }
    return uri.lastPathSegment?.substringAfterLast('/') ?: ""
  }

  private fun stripArchiveExtension(name: String): String =
    name.removeSuffix(".zip").removeSuffix(".ZIP")
}
