#!/bin/bash
# Compiles the real FTP server sources against VeriCopyCore and runs the end-to-end
# socket test (driven by the system curl). Mirrors Scripts/run_queue_test.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/ftp-test"
rm -rf "$OUT"
mkdir -p "$OUT"

swiftc -O -parse-as-library \
    -emit-module -module-name VeriCopyCore \
    -emit-module-path "$OUT/VeriCopyCore.swiftmodule" \
    -emit-library -o "$OUT/libVeriCopyCore.dylib" \
    Sources/VeriCopyCore/*.swift

swiftc -O -parse-as-library \
    -I "$OUT" -L "$OUT" -lVeriCopyCore \
    -Xlinker -rpath -Xlinker "@executable_path" \
    Sources/VeriCopy/FTPServer.swift \
    Sources/VeriCopy/FTPConnection.swift \
    Scripts/ftp_test.swift \
    -o "$OUT/ftp-test"

"$OUT/ftp-test"
