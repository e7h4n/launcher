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
install -Dm755 "$power_dir/standby.py" "$stage/usr/libexec/okou-cardputer-standby"
install -Dm644 "$power_dir/okou-cardputer-standby.service" "$stage/usr/lib/systemd/system/okou-cardputer-standby.service"
install -d "$stage/DEBIAN"
cat > "$stage/DEBIAN/control" <<'EOF'
Package: applaunch-okou
Version: 0.6.105+okou6
Architecture: arm64
Depends: applaunch (= 0.6.105), python3, libdrm2, systemd, udev
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
case "$1" in
    remove|purge|disappear|abort-install)
        if [ -d /run/udev ]; then udevadm control --reload; fi
        if [ -d /run/systemd/system ]; then systemctl daemon-reload; fi
        rm -f /run/okou-cardputer-standby-inhibit
        ;;
    upgrade)
        # A downgrade may replace this package with one that has no standby unit.
        if [ ! -f /usr/lib/systemd/system/okou-cardputer-standby.service ]; then
            rm -f /run/okou-cardputer-standby-inhibit
        fi
        ;;
esac
EOF
cat > "$stage/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -eu
case "$1" in
    configure|abort-upgrade|abort-remove|abort-deconfigure) ;;
    *) exit 0 ;;
esac
rm -f /run/okou-cardputer-standby-inhibit
if [ -d /run/systemd/system ]; then
    systemctl daemon-reload
fi
if [ -d /run/udev ]; then
    udevadm control --reload
    if [ -d /sys/bus/usb/devices/1-1.1 ]; then
        udevadm trigger --action=change /sys/bus/usb/devices/1-1.1
    fi
    if [ -d /sys/class/backlight/backlight ]; then
        udevadm trigger --action=change /sys/class/backlight/backlight
    fi
fi
EOF
cat > "$stage/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -eu
case "$1" in
    remove|upgrade|deconfigure)
        if [ -d /run/systemd/system ]; then
            # Backlight uevents can still arrive until dpkg replaces the rules.
            touch /run/okou-cardputer-standby-inhibit
            systemctl stop okou-cardputer-standby.service ||
                [ "$(systemctl show -p ActiveState --value okou-cardputer-standby.service)" = failed ]
        fi
        /usr/libexec/okou-cardputer-standby restore
        ;;
esac
if [ "$1" = remove ]; then
    /usr/libexec/okou-cardputer-screen-led restore
fi
EOF
chmod 755 "$stage/DEBIAN/postinst" "$stage/DEBIAN/prerm"
chmod 755 "$stage/DEBIAN/preinst" "$stage/DEBIAN/postrm"
dpkg-deb --root-owner-group --build "$stage" "$output"
