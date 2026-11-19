#!/usr/bin/env bash
# Bilgisayar uygulamasını derler ve yalnızca bu kullanıcı için kurar
# (sudo gerekmez). Uygulama menüsünde "Koçum" olarak görünür.
#
# Programın kendisi:  ~/.local/opt/kocum/
# Menü kısayolu:      ~/.local/share/applications/com.kocum.kocum.desktop
# Simge:              ~/.local/share/icons/hicolor/512x512/apps/com.kocum.kocum.png
#
# Verilere (veritabanı, fotoğraflar: ~/.local/share/com.kocum.kocum/) DOKUNULMAZ.
# Kaldırmak için yalnızca yukarıdaki üç yolu sil; veriler yerinde kalır.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -d linux ] || tool/setup_linux.sh
flutter build linux --release

hedef="$HOME/.local/opt/kocum"
paket="build/linux/x64/release/bundle"
[ -x "$paket/kocum" ] || { echo "Derleme bulunamadı: $paket/kocum"; exit 1; }

# Yalnızca program dosyaları yenilenir: önce yeni kopya, sonra yer değiştirme.
mkdir -p "$HOME/.local/opt"
rm -rf "$hedef.yeni"
cp -r "$paket" "$hedef.yeni"
rm -rf "$hedef"
mv "$hedef.yeni" "$hedef"

simge="$HOME/.local/share/icons/hicolor/512x512/apps"
mkdir -p "$simge" "$HOME/.local/share/applications"
cp assets/icon/logo.png "$simge/com.kocum.kocum.png"
sed "s|@EXEC@|$hedef/kocum|" tool/linux/com.kocum.kocum.desktop \
  > "$HOME/.local/share/applications/com.kocum.kocum.desktop"
command -v update-desktop-database >/dev/null 2>&1 \
  && update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

echo "Kuruldu: $hedef/kocum"
echo "Uygulama menüsünde \"Koçum\" olarak görünür."
