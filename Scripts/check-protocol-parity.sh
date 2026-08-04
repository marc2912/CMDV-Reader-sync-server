#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Checks the vendored wire format against the app's copy.
#
# `Sources/CMDVSyncProtocol/SyncProtocol.swift` is a verbatim copy of the same file in the CMDV
# Reader app. In the app's own repository the two ends could not disagree, because both imported
# one file; here they can, because a server anyone can host must build on Linux without the app's
# iOS-only dependencies in the graph. Keeping the copy byte-identical is what makes `diff` a
# sufficient check — so nothing in that file is ever edited on this side.
#
# Usage:
#   Scripts/check-protocol-parity.sh [path-to-CMDV-Reader-checkout]
#
# With no argument it looks for a sibling checkout, which is where it usually is. Exits 0 when the
# copies match, 1 when they differ, and 2 when it cannot find the app to compare against — the
# last is not a failure, since almost nobody building this server has the app checked out.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vendored="${repo_root}/Sources/CMDVSyncProtocol/SyncProtocol.swift"
relative_upstream="Packages/CMDVReaderKit/Sources/CMDVSync/SyncProtocol.swift"

app_root="${1:-${CMDV_READER_PATH:-${repo_root}/../CMDV-Reader}}"
upstream="${app_root}/${relative_upstream}"

if [[ ! -f "${upstream}" ]]; then
    echo "note: no app checkout at '${app_root}', so parity was not checked."
    echo "      Pass the path, or set CMDV_READER_PATH, to compare:"
    echo "        Scripts/check-protocol-parity.sh ~/src/CMDV-Reader"
    exit 2
fi

if diff -u "${upstream}" "${vendored}"; then
    echo "ok: the wire format matches ${upstream}"
    exit 0
fi

cat <<'EOF'

The vendored wire format has drifted from the app's.

Left is the app, right is this repository. The app is the source of truth: copy its file over
this one rather than editing here, and check whether the change needs a protocol version bump —
`SyncProtocolVersion.current` is what stops a newer client from silently corrupting an older
server's data, and a format change that forgets it is the one that does real damage.

    cp <app>/Packages/CMDVReaderKit/Sources/CMDVSync/SyncProtocol.swift \
       Sources/CMDVSyncProtocol/SyncProtocol.swift
EOF
exit 1
