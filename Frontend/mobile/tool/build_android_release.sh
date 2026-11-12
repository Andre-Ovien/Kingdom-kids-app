#!/usr/bin/env bash
set -euo pipefail

release_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${release_script_dir}/.."

release_api_url="${API_BASE_URL:-}"
release_media_hosts="${CONTENT_MEDIA_HOSTS:-}"
release_build_number="${BUILD_NUMBER:-}"

if [[ -z "${release_build_number}" || ! "${release_build_number}" =~ ^[1-9][0-9]*$ || \
      ${#release_build_number} -gt 10 || "${release_build_number}" -gt 2100000000 ]]; then
  echo "BUILD_NUMBER must be a positive integer at most 2100000000, greater than every prior Play upload." >&2
  exit 64
fi

# Additional switches must not override the validated endpoint, signing mode,
# build number or application entry point. Fail closed as Flutter adds flags.
release_extra_arguments=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --obfuscate|--tree-shake-icons|--no-tree-shake-icons|--analyze-size|--no-pub)
      shift
      ;;
    --build-name|--split-debug-info)
      if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
        echo "$1 requires a value." >&2
        exit 64
      fi
      shift 2
      ;;
    --build-name=*|--split-debug-info=*)
      if [[ -z "${1#*=}" || "${1#*=}" == -* ]]; then
        echo "${1%%=*} requires a value." >&2
        exit 64
      fi
      shift
      ;;
    *)
      echo "Unsupported release option: ${1%%=*}. The guarded release configuration cannot be overridden." >&2
      exit 64
      ;;
  esac
done

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter is required to build the Android release." >&2
  exit 64
fi

pinned_flutter_version="$(
  sed -nE 's/.*"flutter"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' .fvmrc
)"
active_flutter_version="$(
  flutter --version --machine |
    sed -nE 's/.*"frameworkVersion"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p'
)"
if [[ -z "${pinned_flutter_version}" || -z "${active_flutter_version}" || \
      "${active_flutter_version}" != "${pinned_flutter_version}" ]]; then
  echo "Use the Flutter version pinned in .fvmrc before building a release." >&2
  exit 64
fi

dart run tool/validate_release_config.dart \
  "${release_api_url}" \
  "${release_media_hosts}"

if [[ ! -f android/key.properties ]] && \
   { [[ -z "${ANDROID_KEYSTORE_PATH:-}" ]] || \
     [[ -z "${ANDROID_KEYSTORE_PASSWORD:-}" ]] || \
     [[ -z "${ANDROID_KEY_ALIAS:-}" ]] || \
     [[ -z "${ANDROID_KEY_PASSWORD:-}" ]]; }; then
  echo "Configure android/key.properties or all ANDROID_KEYSTORE_* variables." >&2
  exit 64
fi

flutter build appbundle \
  --release \
  --build-number="${release_build_number}" \
  --dart-define="API_BASE_URL=${release_api_url}" \
  --dart-define="CONTENT_MEDIA_HOSTS=${release_media_hosts}" \
  ${release_extra_arguments[@]+"${release_extra_arguments[@]}"}
