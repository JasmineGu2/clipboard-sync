# Source this to put the Windows Swift toolchain on PATH: `. scripts/swiftenv.sh`
TC=$(ls -d "$LOCALAPPDATA"/Programs/Swift/Toolchains/*/usr/bin 2>/dev/null | tail -1)
RT=$(ls -d "$LOCALAPPDATA"/Programs/Swift/Runtimes/*/usr/bin 2>/dev/null | tail -1)
export PATH="$TC:$RT:$PATH"
export SDKROOT=$(ls -d "$LOCALAPPDATA"/Programs/Swift/Platforms/*/Windows.platform/Developer/SDKs/Windows.sdk 2>/dev/null | tail -1)
