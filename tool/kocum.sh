#!/usr/bin/env bash
# `kocum` komut satırı aracını her klasörden çalıştırır. Ayrıntı: docs/KOCUM_ARACI.md
set -euo pipefail
exec dart run "$(dirname "$(readlink -f "$0")")/../bin/kocum.dart" "$@"
