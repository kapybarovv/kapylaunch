#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
APP_DATA="${DATA_HOME}/kapylauncher"
RUNTIME="${APP_DATA}/runtime/temurin-21"
GAME_DIR="${APP_DATA}/game"
LAUNCHER_SETTINGS="${APP_DATA}/tl.properties"

mkdir -p "${APP_DATA}" "${GAME_DIR}"
if [[ ! -f "${LAUNCHER_SETTINGS}" ]]; then
    cp "${APP_DIR}/tl.properties" "${LAUNCHER_SETTINGS}"
fi

if [[ ! -x "${RUNTIME}/bin/java" ]]; then
    case "$(uname -m)" in
        x86_64|amd64) ADOPTIUM_ARCH="x64" ;;
        aarch64|arm64) ADOPTIUM_ARCH="aarch64" ;;
        *)
            echo "kapylauncher: Linux architecture '$(uname -m)' is not supported yet." >&2
            exit 1
            ;;
    esac

    DOWNLOAD_DIR="$(mktemp -d "${APP_DATA}/.runtime-install.XXXXXX")"
    trap 'rm -rf -- "${DOWNLOAD_DIR}"' EXIT
    ARCHIVE="${DOWNLOAD_DIR}/temurin-jre.tar.gz"
    CHECKSUM_FILE="${DOWNLOAD_DIR}/temurin-jre.tar.gz.sha256"
    JAVA_URL="https://api.adoptium.net/v3/binary/latest/21/ga/linux/${ADOPTIUM_ARCH}/jre/hotspot/normal/eclipse"

    echo "Downloading the Java 21 runtime required by kapylauncher…"
    curl --fail --location --retry 3 --silent --show-error "${JAVA_URL}" -o "${ARCHIVE}"
    curl --fail --location --retry 3 --silent --show-error "${JAVA_URL}.sha256.txt" -o "${CHECKSUM_FILE}"
    EXPECTED_SHA="$(awk 'NR == 1 { print $1 }' "${CHECKSUM_FILE}")"
    ACTUAL_SHA="$(sha256sum "${ARCHIVE}" | awk '{ print $1 }')"
    if [[ -z "${EXPECTED_SHA}" || "${EXPECTED_SHA,,}" != "${ACTUAL_SHA,,}" ]]; then
        echo "kapylauncher: Java runtime checksum verification failed." >&2
        exit 1
    fi

    mkdir -p "${DOWNLOAD_DIR}/runtime"
    tar -xzf "${ARCHIVE}" --strip-components=1 -C "${DOWNLOAD_DIR}/runtime"
    mkdir -p "$(dirname -- "${RUNTIME}")"
    mv "${DOWNLOAD_DIR}/runtime" "${RUNTIME}"
    rm -rf -- "${DOWNLOAD_DIR}"
    trap - EXIT
fi

exec "${RUNTIME}/bin/java" \
    -Dtlauncher.bootstrap.dir="${APP_DIR}" \
    -Dtlauncher.logFolder="${APP_DATA}/logs" \
    -Djna.tmpdir="${APP_DATA}/tmp/jna" \
    -jar "${APP_DIR}/launcher/bootstrap.jar" \
    --brand kapylauncher \
    --packageMode portable \
    --targetJar "${APP_DIR}/launcher/launcher.jar" \
    --targetLibFolder "${APP_DIR}/launcher/libraries" \
    -- \
    --settings "${LAUNCHER_SETTINGS}" \
    --directory "${GAME_DIR}"
