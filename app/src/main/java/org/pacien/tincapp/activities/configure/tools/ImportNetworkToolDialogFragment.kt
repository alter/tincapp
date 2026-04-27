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

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import java8.util.concurrent.CompletableFuture
import org.pacien.tincapp.R
import org.pacien.tincapp.commands.Executor.supplyAsyncTask
import org.pacien.tincapp.context.AppPaths
import org.pacien.tincapp.databinding.ConfigureToolsDialogNetworkImportBinding
import org.pacien.tincapp.utils.isParentOf
import org.pacien.tincapp.utils.makePublic
import java.io.File
import java.io.FileNotFoundException
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream

/**
 * @author euxane
 */
class ImportNetworkToolDialogFragment : ConfigurationToolDialogFragment() {
  companion object {
    private const val REQUEST_PICK_ARCHIVE = 0x12C0
    private val ARCHIVE_MIME_TYPES = arrayOf(
      "application/zip",
      "application/x-zip-compressed",
      "application/octet-stream"
    )
  }

  private var importDialog: ConfigureToolsDialogNetworkImportBinding? = null
  private var selectedArchive: Uri? = null

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    if (requestCode == REQUEST_PICK_ARCHIVE && resultCode == Activity.RESULT_OK) {
      data?.data?.let { uri ->
        selectedArchive = uri
        importDialog?.archivePath?.setText(displayNameOf(uri))
      }
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
    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
      .addCategory(Intent.CATEGORY_OPENABLE)
      .setType("*/*")
      .putExtra(Intent.EXTRA_MIME_TYPES, ARCHIVE_MIME_TYPES)
    startActivityForResult(intent, REQUEST_PICK_ARCHIVE)
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

        target.parentFile?.mkdirs()
        val source = effectiveRoot(staging)
        if (!source.renameTo(target)) {
          source.copyRecursively(target, overwrite = false)
        }
        target.makePublic()
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
