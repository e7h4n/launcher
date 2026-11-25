#!/bin/sh
# Package the customized executable and handheld power policy. The base package owns the assets.
set -eu
binary=${1:?expected path to the built launcher}
output=${2:?expected output deb path}
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
# fb_load matches /proc/PID/exe against this exact path before releasing the LCD.
install -Dm755 "$binary" "$stage/usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch"
power_dir=$(dirname "$0")/okou-power
install -Dm644 "$power_dir/90-okou-cardputer-power.rules" "$stage/usr/lib/udev/rules.d/90-okou-cardputer-power.rules"
install -Dm755 "$power_dir/screen-led" "$stage/usr/libexec/okou-cardputer-screen-led"
install -d "$stage/DEBIAN"
cat > "$stage/DEBIAN/control" <<'EOF'
Package: applaunch-okou
Version: 0.6.105+okou4
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
cat > "$stage/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -eu
if [ "$1" = configure ] && [ -d /run/udev ]; then
    udevadm control --reload
    if [ -d /sys/bus/usb/devices/1-1.1 ]; then
        udevadm trigger --action=change /sys/bus/usb/devices/1-1.1
    fi
    /usr/libexec/okou-cardputer-screen-led
fi
EOF
cat > "$stage/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -eu
if [ "$1" = remove ]; then
    /usr/libexec/okou-cardputer-screen-led restore
fi
EOF
chmod 755 "$stage/DEBIAN/postinst" "$stage/DEBIAN/prerm"
chmod 755 "$stage/DEBIAN/preinst" "$stage/DEBIAN/postrm"
dpkg-deb --root-owner-group --build "$stage" "$output"
