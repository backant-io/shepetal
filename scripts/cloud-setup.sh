#!/bin/bash
# Setup script for the "backant" Claude Code cloud environment (paste into its Setup script field).
# Runs as root on Ubuntu 24.04 and must exit 0. Adds the Swift toolchain so shepetal's
# platform-independent Swift code (fn gesture timing, model selection) builds and tests on Linux;
# the macOS app itself only builds on a Mac.
V=6.2.4
case "$(uname -m)" in aarch64) A=-aarch64 ;; *) A= ;; esac
if ! command -v swift >/dev/null; then
  apt-get update -qq && apt-get install -y -qq binutils libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev \
    libncurses-dev libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev libz3-dev pkg-config zlib1g-dev >/dev/null || true
  curl -fsSL "https://download.swift.org/swift-$V-release/ubuntu2404$A/swift-$V-RELEASE/swift-$V-RELEASE-ubuntu24.04$A.tar.gz" \
    | tar -xz -C /opt && ln -sf /opt/swift-$V-RELEASE-ubuntu24.04$A/usr/bin/* /usr/local/bin/ || true
fi
swift --version || true
