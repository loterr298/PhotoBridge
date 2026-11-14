#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PHOTO_ROTATE_ROOT="${PHOTO_ROTATE_ROOT:-/Users/l/Documents/New project/photo-rotate-ui-20261014-v18}"

# PhotoRotate owns its own signed replacement/rollback routine.
if [[ -f "$PHOTO_ROTATE_ROOT/install.py" && -d "$PHOTO_ROTATE_ROOT/outputs/Photo旋转.app" ]]; then
  python3 "$PHOTO_ROTATE_ROOT/install.py"
else
  echo "Photo旋转源码工程未找到，跳过 Photo旋转自动安装：$PHOTO_ROTATE_ROOT" >&2
fi

# PhotoBridgeMac is an unsigned local development build; ditto replaces the
# app bundle in place so Finder and LaunchServices see the new executable.
if [[ -d "$ROOT_DIR/build/PhotoBridgeMac.app" ]]; then
  ditto "$ROOT_DIR/build/PhotoBridgeMac.app" /Applications/PhotoBridgeMac.app
  codesign --verify --strict /Applications/PhotoBridgeMac.app
  echo "已自动安装 PhotoBridgeMac：/Applications/PhotoBridgeMac.app"
else
  echo "PhotoBridgeMac 构建产物不存在，跳过自动安装。" >&2
fi
