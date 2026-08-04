#!/bin/bash
set -euo pipefail

developer_dir="$(xcode-select -p)"
testing_frameworks="$developer_dir/Library/Developer/Frameworks"
testing_libraries="$developer_dir/Library/Developer/usr/lib"
test_arguments=(--disable-xctest --enable-swift-testing)

# Command Line Tools installs Swift Testing outside SwiftPM's default search paths.
if [[ -d "$testing_frameworks/Testing.framework" ]]; then
    test_arguments+=(
        -Xswiftc -F -Xswiftc "$testing_frameworks"
        -Xlinker -F -Xlinker "$testing_frameworks"
        -Xlinker -rpath -Xlinker "$testing_frameworks"
        -Xlinker -rpath -Xlinker "$testing_libraries"
    )
fi

swift test "${test_arguments[@]}"
