#!/usr/bin/env bash
# Linux: bilgisayar uygulamasının iskeletini kurar, bağımlılıkları indirir,
# kodu üretir. Telefon tarafına (android/) dokunmaz.
set -euo pipefail
cd "$(dirname "$0")/.."

eksik=()
for k in flutter clang cmake ninja pkg-config; do
  command -v "$k" >/dev/null 2>&1 || eksik+=("$k")
done
if command -v pkg-config >/dev/null 2>&1 && ! pkg-config --exists gtk+-3.0; then
  eksik+=("gtk3 (geliştirme dosyaları)")
fi
if [ ${#eksik[@]} -gt 0 ]; then
  echo "Eksik araçlar: ${eksik[*]}"
  echo "  Arch / CachyOS:  sudo pacman -S --needed clang cmake ninja pkgconf gtk3"
  echo "  Ubuntu / Debian: sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev"
  echo "  Flutter:         https://docs.flutter.dev/get-started/install/linux"
  exit 1
fi

flutter config --enable-linux-desktop >/dev/null

if [ ! -d linux ]; then
  tmp="$(mktemp -d)"
  flutter create --org com.kocum --project-name kocum --platforms linux "$tmp/kocum"
  cp -r "$tmp/kocum/linux" ./linux
  rm -rf "$tmp"
fi

flutter pub get
dart run build_runner build --delete-conflicting-outputs

echo
echo "Hazır. Çalıştır:      flutter run -d linux"
echo "Menüye kur:           tool/install_linux.sh"
