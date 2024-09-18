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

package org.pacien.tincapp.storageprovider

import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.database.Cursor
import android.database.MatrixCursor
import android.os.Build
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import androidx.annotation.RequiresApi
import org.pacien.tincapp.R
import org.pacien.tincapp.context.AppPaths
import java.io.File
import java.io.FileNotFoundException
import kotlin.io.path.Path
import kotlin.io.path.name
import kotlin.io.path.relativeTo

class FilesDocumentsProvider : DocumentsProvider() {
  companion object {
    const val ROOT_ID = ""
    const val ROOT_DOCUMENT_ID = "/"
    const val VIRTUAL_ROOT_NETWORKS = "networks"
    const val VIRTUAL_ROOT_LOG = "log"

    private val DEFAULT_ROOT_PROJECTION = arrayOf(
      Root.COLUMN_ROOT_ID,
      Root.COLUMN_MIME_TYPES,
      Root.COLUMN_FLAGS,
      Root.COLUMN_ICON,
      Root.COLUMN_TITLE,
      Root.COLUMN_SUMMARY,
      Root.COLUMN_DOCUMENT_ID,
      Root.COLUMN_AVAILABLE_BYTES,
    )

    private val DEFAULT_DOCUMENT_PROJECTION = arrayOf(
      Document.COLUMN_DOCUMENT_ID,
      Document.COLUMN_MIME_TYPE,
      Document.COLUMN_DISPLAY_NAME,
      Document.COLUMN_LAST_MODIFIED,
      Document.COLUMN_FLAGS,
      Document.COLUMN_SIZE,
    )
  }

  override fun onCreate(): Boolean = true

  override fun queryRoots(projection: Array<out String>?): Cursor =
    MatrixCursor(projection ?: DEFAULT_ROOT_PROJECTION).apply {
      addRow(
        Root.COLUMN_ROOT_ID to ROOT_ID,
        Root.COLUMN_DOCUMENT_ID to ROOT_DOCUMENT_ID,
        Root.COLUMN_FLAGS to (Root.FLAG_SUPPORTS_CREATE or Root.FLAG_SUPPORTS_IS_CHILD),
        Root.COLUMN_MIME_TYPES to "*/*",
        Root.COLUMN_TITLE to context!!.getString(R.string.app_name),
        Root.COLUMN_ICON to R.mipmap.ic_launcher,
      )
    }

  override fun queryDocument(documentId: String?, projection: Array<out String>?): Cursor =
    MatrixCursor(projection ?: DEFAULT_DOCUMENT_PROJECTION).apply {
      when (documentId) {
        ROOT_DOCUMENT_ID -> addVirtualDirRow(ROOT_DOCUMENT_ID)
        else -> addFileRow(documentId!!, fileForDocumentId(documentId))
      }
    }

  override fun queryChildDocuments(
    parentDocumentId: String?,
    projection: Array<out String>?,
    sortOrder: String?
  ): Cursor =
    MatrixCursor(projection ?: DEFAULT_DOCUMENT_PROJECTION).apply {
      when (parentDocumentId) {
        ROOT_DOCUMENT_ID -> {
          addVirtualDirRow(VIRTUAL_ROOT_NETWORKS)
          addVirtualDirRow(VIRTUAL_ROOT_LOG)
        }

        else -> fileForDocumentId(parentDocumentId!!).listFiles()?.forEach {
          addFileRow(documentIdForFile(it), it)
        }
      }
    }

  @RequiresApi(Build.VERSION_CODES.O)
  override fun findDocumentPath(
    parentDocumentId: String?,
    childDocumentId: String?
  ): DocumentsContract.Path {
    var childPath = Path(childDocumentId!!)
    if (parentDocumentId != null)
      childPath = childPath.relativeTo(Path(parentDocumentId))

    val components = childPath.asSequence().map { it.name }.toList()
    return DocumentsContract.Path(ROOT_ID, listOf(ROOT_DOCUMENT_ID) + components)
  }

  override fun isChildDocument(parentDocumentId: String?, documentId: String?): Boolean =
    fileForDocumentId(parentDocumentId!!).isParentOf(fileForDocumentId(documentId!!))

  override fun getDocumentType(documentId: String?): String =
    fileForDocumentId(documentId!!).documentMimeType()

  override fun deleteDocument(documentId: String?) {
    fileForDocumentId(documentId!!).apply {
      if (!deleteRecursively()) throw FileSystemException(this)
    }
  }

  override fun openDocument(
    documentId: String?,
    mode: String?,
    signal: CancellationSignal?
  ): ParcelFileDescriptor =
    ParcelFileDescriptor.open(
      fileForDocumentId(documentId!!),
      ParcelFileDescriptor.parseMode(mode),
    )

  override fun createDocument(
    parentDocumentId: String?,
    mimeType: String?,
    displayName: String?
  ): String =
    File(fileForDocumentId(parentDocumentId!!), displayName!!).apply {
      val success = when (mimeType) {
        Document.MIME_TYPE_DIR -> mkdir()
        else -> createNewFile()
      }
      if (!success) throw FileSystemException(this)
    }.let {
      documentIdForFile(it)
    }

  private fun fileForDocumentId(documentId: String): File =
    documentId.split(File.separatorChar, limit = 2).let {
      val root = it[0]
      val under = if (it.size >= 2) it[1] else ""
      when (root) {
        VIRTUAL_ROOT_NETWORKS -> File(AppPaths.confDir(), under)
        VIRTUAL_ROOT_LOG -> File(AppPaths.logDir(), under)
        else -> throw FileNotFoundException()
      }
    }

  private fun documentIdForFile(file: File): String =
    if (AppPaths.confDir().isParentOf(file)) {
      File(VIRTUAL_ROOT_NETWORKS, file.pathUnder(AppPaths.confDir())).path
    } else if (AppPaths.logDir().isParentOf(file)) {
      File(VIRTUAL_ROOT_LOG, file.pathUnder(AppPaths.logDir())).path
    } else {
      throw IllegalArgumentException()
    }

  private fun File.pathUnder(parent: File): String =
    canonicalPath.removePrefix(parent.canonicalPath)

  private fun File.isParentOf(childCandidate: File): Boolean {
    var parentOfChild = childCandidate.canonicalFile.parentFile
    while (parentOfChild != null) {
      if (parentOfChild.equals(canonicalFile)) return true
      parentOfChild = parentOfChild.parentFile
    }
    return false
  }

  private fun File.documentMimeType() =
    if (isDirectory) Document.MIME_TYPE_DIR
    else "text/plain"

  private fun File.documentPermFlags() =
    (if (isDirectory && canWrite()) Document.FLAG_DIR_SUPPORTS_CREATE else 0) or
      (if (isFile && canWrite()) Document.FLAG_SUPPORTS_WRITE else 0) or
      (if (parentFile?.canWrite() == true) Document.FLAG_SUPPORTS_DELETE else 0)

  private fun MatrixCursor.addFileRow(documentId: String, file: File) {
    addRow(
      Document.COLUMN_DOCUMENT_ID to documentId,
      Document.COLUMN_DISPLAY_NAME to file.name,
      Document.COLUMN_SIZE to file.length(),
      Document.COLUMN_LAST_MODIFIED to file.lastModified(),
      Document.COLUMN_MIME_TYPE to file.documentMimeType(),
      Document.COLUMN_FLAGS to file.documentPermFlags(),
    )
  }

  private fun MatrixCursor.addVirtualDirRow(documentId: String) {
    addRow(
      Document.COLUMN_DOCUMENT_ID to documentId,
      Document.COLUMN_DISPLAY_NAME to documentId,
      Document.COLUMN_MIME_TYPE to Document.MIME_TYPE_DIR,
      Document.COLUMN_FLAGS to Document.FLAG_DIR_SUPPORTS_CREATE,
    )
  }

  private fun MatrixCursor.addRow(vararg pairs: Pair<String, Any?>) {
    val row = newRow()
    pairs.forEach { row.add(it.first, it.second) }
  }
}