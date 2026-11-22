#!/bin/sh
# Package only the customized executable. The base package owns the device assets.
set -eu
binary=${1:?expected path to the built launcher}
output=${2:?expected output deb path}
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
install -Dm755 "$binary" "$stage/usr/lib/applaunch-okou/M5CardputerZero-APPLaunch"
install -d "$stage/DEBIAN" "$stage/usr/lib/systemd/user/APPLaunch.service.d"
cat > "$stage/DEBIAN/control" <<'EOF'
Package: applaunch-okou
Version: 0.6.105+okou1
Architecture: arm64
Depends: applaunch (= 0.6.105)
Maintainer: Okou <engineering@okou.ai>
Description: Cardputer Zero launcher with optional Okou startup
EOF
cat > "$stage/usr/lib/systemd/user/APPLaunch.service.d/50-okou.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/lib/applaunch-okou/M5CardputerZero-APPLaunch
EOF
dpkg-deb --root-owner-group --build "$stage" "$output"
