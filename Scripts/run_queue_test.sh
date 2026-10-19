#!/bin/bash
# Compiles the real QueueViewModel/TransferJob sources against VeriCopyCore and
# runs the headless queue-sequencing test.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/queue-test"
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
    Sources/VeriCopy/TransferJob.swift \
    Sources/VeriCopy/QueueViewModel.swift \
    Sources/VeriCopy/NotificationChannel.swift \
    Sources/VeriCopy/PowerController.swift \
    Scripts/queue_test.swift \
    -o "$OUT/queue-test"

"$OUT/queue-test"
