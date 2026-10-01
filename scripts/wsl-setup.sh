set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git binutils gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libncurses-dev libpython3-dev libsqlite3-0 libsqlite3-dev libstdc++-13-dev libxml2-dev libz3-dev pkg-config tzdata unzip zlib1g-dev >/dev/null
cd /root
curl -sSO https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar zxf swiftly-$(uname -m).tar.gz
./swiftly init --quiet-shell-followup --assume-yes --skip-install
. /root/.local/share/swiftly/env.sh
swiftly install --use 6.3 --assume-yes
swift --version
echo WSL_SWIFT_OK
