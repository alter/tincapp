/*
 * Tinc Mesh VPN: Android client and user interface
 * Copyright (C) 2017-2018 Euxane P. TRAN-GIRARD
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

package org.pacien.tincapp.extensions

import org.apache.commons.configuration2.Configuration
import org.apache.commons.configuration2.PropertiesConfiguration
import org.apache.commons.configuration2.builder.fluent.Configurations
import org.pacien.tincapp.data.CidrAddress
import java.io.File

/**
 * @author euxane
 */
object ApacheConfiguration {
  fun Configuration.getStringList(key: String): List<String> = getList(String::class.java, key, emptyList())
  fun Configuration.getCidrList(key: String): List<CidrAddress> = getStringList(key).map { CidrAddress.fromSlashSeparated(it) }
  fun Configuration.getIntList(key: String): List<Int> = getList(Int::class.java, key, emptyList())
  fun Configuration.getFile(key: String): File? = getString(key)?.let { File(it) }

  // tinc config files never use ${var} substitutions; leaving the
  // default ConfigurationInterpolator enabled exposes the parser to
  // CVE-2022-33980-class lookups (script, dns, url) when an attacker
  // controls the file content - e.g. through the network import
  // feature. Disable interpolation entirely and return raw values.
  fun loadSafeProperties(f: File): PropertiesConfiguration =
    Configurations().properties(f).apply { interpolator = null }
}
