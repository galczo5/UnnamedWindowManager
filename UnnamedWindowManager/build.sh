#!/bin/bash
set -e

xcodebuild \
  -project UnnamedWindowManager.xcodeproj \
  -scheme UnnamedWindowManager \
  build
