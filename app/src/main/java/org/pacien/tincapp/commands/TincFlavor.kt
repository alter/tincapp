/*
 * Tinc Mesh VPN: Android client and user interface
 * Copyright (C) 2017-2026 Euxane P. TRAN-GIRARD
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

package org.pacien.tincapp.commands

import android.os.Build
import org.pacien.tincapp.context.AppPaths
import org.pacien.tincapp.data.TincConfiguration
import java.io.File

/**
 * Which tinc daemon implementation a given network is using.
 *
 * Source of truth is the network's `tinc.conf`: a `TransportMode = quic`
 * directive selects the QUIC fork (link0ln/tinc-quic + msquic), anything
 * else - including a missing key - selects the upstream tinc 1.1pre18
 * compiled into the app.
 */
enum class TincFlavor {
  CLASSIC,
  QUIC;

  companion object {
    private const val MIN_API_FOR_QUIC = Build.VERSION_CODES.UPSIDE_DOWN_CAKE // API 34, Android 14

    /**
     * Read tinc.conf for [netName] and decide which flavor it asks for.
     * Returns [CLASSIC] when the file is missing or has no transport mode
     * set, so freshly-imported networks behave exactly as before.
     */
    fun forNetwork(netName: String): TincFlavor {
      val confFile = AppPaths.tincConfFile(netName)
      if (!confFile.exists()) return CLASSIC
      val transport = runCatching { TincConfiguration.fromTincConfiguration(confFile).transportMode }
        .getOrNull()
        ?.trim()
        ?.lowercase()
      return when (transport) {
        "quic" -> QUIC
        else -> CLASSIC
      }
    }

    fun isSupportedOnThisDevice(flavor: TincFlavor): Boolean = when (flavor) {
      CLASSIC -> true
      QUIC -> Build.VERSION.SDK_INT >= MIN_API_FOR_QUIC
    }
  }

  /** Daemon binary that should run a network of this flavor. */
  fun tincdBinary(): File = when (this) {
    CLASSIC -> AppPaths.tincd()
    QUIC -> AppPaths.tincdQuic()
  }

  /** Control CLI binary that pairs with [tincdBinary]. */
  fun tincBinary(): File = when (this) {
    CLASSIC -> AppPaths.tinc()
    QUIC -> AppPaths.tincQuic()
  }
}
