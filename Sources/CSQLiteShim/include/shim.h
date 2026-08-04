/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

/* SQLite, reached through a shim rather than through `import SQLite3`.
 *
 * `import SQLite3` exists only on Apple platforms. A server anyone can host has to
 * build on Linux, and a shim target is the portable way to get the same C API on
 * both — it is a header include and a link flag, with no dependency added. */

#ifndef CMDV_SQLITE_SHIM_H
#define CMDV_SQLITE_SHIM_H

#include <sqlite3.h>

#endif
