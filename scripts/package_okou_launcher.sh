#!/bin/sh
# Package only the customized executable. The base package owns the device assets.
set -eu
binary=${1:?expected path to the built launcher}
output=${2:?expected output deb path}
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
# fb_load matches /proc/PID/exe against this exact path before releasing the LCD.
install -Dm755 "$binary" "$stage/usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch"
install -d "$stage/DEBIAN"
cat > "$stage/DEBIAN/control" <<'EOF'
Package: applaunch-okou
Version: 0.6.105+okou3
Architecture: arm64
Depends: applaunch (= 0.6.105)
Maintainer: Okou <engineering@okou.ai>
Description: Cardputer Zero launcher with optional Okou startup
EOF
cat > "$stage/DEBIAN/preinst" <<'EOF'
#!/bin/sh
set -eu
case "$1" in
    install|upgrade)
        launcher=/usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch
        dpkg-divert --package applaunch-okou --add --rename --divert "$launcher.distrib" "$launcher"
        ;;
esac
EOF
cat > "$stage/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -eu
case "$1" in
    remove|abort-install|disappear) restore=yes ;;
    abort-upgrade)
        if dpkg --compare-versions "${2:-0}" lt 0.6.105+okou2; then restore=yes; fi
        ;;
esac
if [ "${restore:-no}" = yes ]; then
    launcher=/usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch
    if [ "$(dpkg-divert --listpackage "$launcher")" = applaunch-okou ]; then
        dpkg-divert --package applaunch-okou --remove --rename --divert "$launcher.distrib" "$launcher"
    fi
fi
EOF
chmod 755 "$stage/DEBIAN/preinst" "$stage/DEBIAN/postrm"
dpkg-deb --root-owner-group --build "$stage" "$output"
