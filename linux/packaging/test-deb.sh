#!/bin/sh
# Installs the .deb in a clean Ubuntu 24.04 (run as root inside the container) and checks it.
#   docker run --rm -v "$PWD/linux":/src -w /src ubuntu:24.04 packaging/test-deb.sh target/debian/shepetal_*.deb
set -eu
deb=$(readlink -f "$1")
fixture=$(readlink -f "$(dirname "$0")/../fixtures/pw-dump-meeting.json")
export DEBIAN_FRONTEND=noninteractive
log=$(mktemp)
fail() { echo "FAIL: $*" >&2; exit 1; }
link() { echo "/home/$1/.config/systemd/user/graphical-session.target.wants/shepetal.service"; }
preseed() { printf 'shepetal shepetal/enable-user-service boolean %s\nshepetal shepetal/service-user string %s\n' "$1" "$2" | debconf-set-selections; }

apt-get update -qq
apt-get install -y -qq systemd >/dev/null
groupadd -f -r input  # udev makes it on a desktop; the minimal image has none
useradd -m alice
useradd -m bob
usermod -aG input bob

echo "== install as alice, no answer given (default: no)"
SUDO_USER=alice apt-get install -y -qq "$deb" >"$log" 2>&1 || { cat "$log"; fail "install"; }
cat "$log" | sed -n '/^shepetal:/,/^Start at login/p'
grep -q 'sudo usermod -aG input alice' "$log" || fail "postinst does not tell alice to join the input group"
grep -q "run 'shepetal probe'" "$log" || fail "postinst does not mention shepetal probe"
grep -q 'Start at login: not enabled' "$log" || fail "postinst claims the service is enabled"
[ ! -e "$(link alice)" ] || fail "service enabled for alice without her consent"

echo "== smoke: shepetal probe --pw-dump fixture"
out=$(shepetal probe --pw-dump "$fixture")
echo "$out"
echo "$out" | grep -q 'mic user:  ZOOM VoiceEngine (zoom) meeting=Some("Zoom")' || fail "probe misses the Zoom call"
echo "$out" | grep -q '^fn key:' || fail "probe has no fn key line"

echo "== files"
for f in /usr/bin/shepetal /usr/lib/systemd/user/shepetal.service /usr/share/applications/shepetal.desktop \
         /usr/share/icons/hicolor/scalable/apps/shepetal.svg /usr/lib/shepetal/user-service /usr/lib/shepetal/launch; do
    [ -e "$f" ] || fail "missing $f"
done
XDG_RUNTIME_DIR=$(mktemp -d) systemd-analyze verify --user /usr/lib/systemd/user/shepetal.service || fail "unit does not verify"

echo "== reinstall as bob, who agrees"
preseed true bob
SUDO_USER=bob dpkg -i "$deb" >"$log" 2>&1 || { cat "$log"; fail "reinstall"; }
grep -q 'bob is already in the input group' "$log" || fail "postinst misses bob's input group"
grep -q 'Start at login: enabled for bob' "$log" || fail "postinst does not report the enabled service"
[ "$(readlink "$(link bob)")" = /usr/lib/systemd/user/shepetal.service ] || fail "service not enabled for bob"
[ "$(stat -c %U "$(link bob)")" = bob ] || fail "bob's link is not owned by bob"
[ "$(stat -c %U /home/bob/.config/systemd)" = bob ] || fail "bob's systemd dir is not owned by bob"
[ ! -e "$(link alice)" ] || fail "bob's answer enabled alice"

echo "== upgrade by alice does not reuse bob's yes"
SUDO_USER=alice dpkg -i "$deb" >"$log" 2>&1 || { cat "$log"; fail "upgrade"; }
[ ! -e "$(link alice)" ] || fail "alice got bob's answer"

echo "== root install never touches /root"
preseed true root
dpkg -i "$deb" >"$log" 2>&1 || { cat "$log"; fail "root install"; }
[ ! -e /root/.config/systemd ] || fail "service enabled for root"

echo "== remove undoes the enable"
apt-get remove -y -qq shepetal >/dev/null 2>&1
[ ! -L "$(link bob)" ] || fail "remove left bob's link behind"
[ ! -e /usr/bin/shepetal ] || fail "binary still there"
dpkg --purge shepetal >/dev/null
[ ! -e /var/lib/shepetal ] || fail "purge left /var/lib/shepetal"
echo "PASS"
