#!/usr/bin/env bash
# Downloads pinned third-party dependencies and models, verifying SHA-256 checksums.
# Usage: scripts/fetch_deps.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
THIRD_PARTY="$ROOT/third_party"
MODELS="$ROOT/models"

ORT_VERSION="1.31.0"
ORT_SHA256="1031b36dd3bdaa8d976a6130d9cf2a05e9be320b93ae804f8427b91dc3432afc"

# YuNet face detector (MIT), OpenCV model zoo.
YUNET_SHA256="8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"

STB_COMMIT="003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5"
STB_IMAGE_SHA256="594c2fe35d49488b4382dbfaec8f98366defca819d916ac95becf3e75f4200b3"
STB_IMAGE_WRITE_SHA256="cbd5f0ad7a9cf4468affb36354a1d2338034f2c12473cf1a8e32053cb6914a05"

# fetch URL DEST SHA256: downloads unless DEST already exists with the right hash.
fetch() {
    local url="$1" dest="$2" sha="$3"
    if [[ -f "$dest" ]] && echo "$sha  $dest" | shasum -a 256 -c --status; then
        return
    fi
    mkdir -p "$(dirname "$dest")"
    echo "Downloading $(basename "$dest")"
    curl -sfL -o "$dest.part" "$url"
    if ! echo "$sha  $dest.part" | shasum -a 256 -c --status; then
        rm -f "$dest.part"
        echo "error: checksum mismatch for $url" >&2
        exit 1
    fi
    mv "$dest.part" "$dest"
}

case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) ORT_PLATFORM="osx-arm64" ;;
    *) echo "error: only macOS arm64 is set up so far" >&2; exit 1 ;;
esac

ORT_ARCHIVE="$THIRD_PARTY/downloads/onnxruntime-$ORT_PLATFORM-$ORT_VERSION.tgz"
fetch "https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VERSION/onnxruntime-$ORT_PLATFORM-$ORT_VERSION.tgz" \
    "$ORT_ARCHIVE" "$ORT_SHA256"
if [[ ! -f "$THIRD_PARTY/onnxruntime/VERSION_NUMBER" ]] || [[ "$(cat "$THIRD_PARTY/onnxruntime/VERSION_NUMBER")" != "$ORT_VERSION" ]]; then
    rm -rf "$THIRD_PARTY/onnxruntime"
    mkdir -p "$THIRD_PARTY/onnxruntime"
    tar xzf "$ORT_ARCHIVE" -C "$THIRD_PARTY/onnxruntime" --strip-components 2
fi

fetch "https://raw.githubusercontent.com/nothings/stb/$STB_COMMIT/stb_image.h" \
    "$THIRD_PARTY/stb/stb_image.h" "$STB_IMAGE_SHA256"
fetch "https://raw.githubusercontent.com/nothings/stb/$STB_COMMIT/stb_image_write.h" \
    "$THIRD_PARTY/stb/stb_image_write.h" "$STB_IMAGE_WRITE_SHA256"

fetch "https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx" \
    "$MODELS/face_detection_yunet_2023mar.onnx" "$YUNET_SHA256"

echo "Dependencies ready."
