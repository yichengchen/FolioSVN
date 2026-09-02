#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
runtime_directory="$repository_root/Vendor/SVNRuntime"
source_svn="${1:-$(command -v svn || true)}"

fail() {
    echo "error: $*" >&2
    exit 1
}

is_system_library() {
    case "$1" in
        /System/*|/usr/lib/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

[ -n "$source_svn" ] || fail "svn was not found; pass its absolute path as the first argument"
[ -x "$source_svn" ] || fail "$source_svn is not executable"
[ "$runtime_directory" = "$repository_root/Vendor/SVNRuntime" ] || fail "unexpected runtime destination"

source_architectures="$(lipo -archs "$source_svn")"
case " $source_architectures " in
    *" arm64 "*) ;;
    *) fail "the source svn does not contain arm64: $source_architectures" ;;
esac

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/svnclient-runtime.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT

staged_runtime="$work_directory/SVNRuntime"
queue_file="$work_directory/queue.txt"
processed_file="$work_directory/processed.txt"
license_roots_file="$work_directory/license-roots.txt"

mkdir -p "$staged_runtime/bin" "$staged_runtime/lib" "$staged_runtime/licenses"
: > "$processed_file"
: > "$license_roots_file"
printf '%s\n' "$source_svn" > "$queue_file"

queue_index=1
while :; do
    source_file="$(sed -n "${queue_index}p" "$queue_file")"
    [ -n "$source_file" ] || break
    queue_index=$((queue_index + 1))

    if grep -Fqx "$source_file" "$processed_file"; then
        continue
    fi
    printf '%s\n' "$source_file" >> "$processed_file"

    [ -f "$source_file" ] || fail "dependency does not exist: $source_file"
    canonical_source="$(realpath "$source_file")"

    if [ "$source_file" = "$source_svn" ]; then
        destination_file="$staged_runtime/bin/svn"
    else
        destination_file="$staged_runtime/lib/$(basename "$source_file")"
    fi

    if [ -e "$destination_file" ]; then
        source_checksum="$(shasum -a 256 "$source_file" | awk '{print $1}')"
        destination_checksum="$(shasum -a 256 "$destination_file" | awk '{print $1}')"
        [ "$source_checksum" = "$destination_checksum" ] \
            || fail "two different libraries have the same basename: $(basename "$source_file")"
    else
        cp -L "$source_file" "$destination_file"
        chmod u+w "$destination_file"
    fi

    if [[ "$canonical_source" =~ ^(/opt/homebrew|/usr/local)/Cellar/([^/]+)/([^/]+)/ ]]; then
        cellar_root="${BASH_REMATCH[1]}/Cellar/${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
        if ! grep -Fqx "$cellar_root" "$license_roots_file"; then
            printf '%s\n' "$cellar_root" >> "$license_roots_file"
        fi
    fi

    while IFS= read -r dependency; do
        [ -n "$dependency" ] || continue
        if is_system_library "$dependency"; then
            continue
        fi
        case "$dependency" in
            /*)
                [ -e "$dependency" ] || fail "dependency does not exist: $dependency"
                printf '%s\n' "$dependency" >> "$queue_file"
                ;;
            *)
                fail "unsupported non-absolute dependency in source artifact: $dependency"
                ;;
        esac
    done < <(otool -L "$source_file" | sed '1d' | awk '{print $1}')
done

targets=("$staged_runtime/bin/svn")
for library in "$staged_runtime"/lib/*.dylib; do
    [ -e "$library" ] || continue
    targets+=("$library")
done

for target in "${targets[@]}"; do
    while IFS= read -r dependency; do
        [ -n "$dependency" ] || continue
        if is_system_library "$dependency"; then
            continue
        fi

        dependency_name="$(basename "$dependency")"
        [ -f "$staged_runtime/lib/$dependency_name" ] \
            || fail "bundled dependency is missing: $dependency_name (required by $(basename "$target"))"

        if [ "$target" = "$staged_runtime/bin/svn" ]; then
            replacement="@loader_path/../lib/$dependency_name"
        else
            replacement="@loader_path/$dependency_name"
        fi
        install_name_tool -change "$dependency" "$replacement" "$target"
    done < <(otool -L "$target" | sed '1d' | awk '{print $1}')

    if [ "$target" != "$staged_runtime/bin/svn" ]; then
        install_name_tool -id "@loader_path/$(basename "$target")" "$target"
    fi
done

while IFS= read -r cellar_root; do
    [ -n "$cellar_root" ] || continue
    formula_name="$(basename "$(dirname "$cellar_root")")"
    formula_version="$(basename "$cellar_root")"
    license_destination="$staged_runtime/licenses/${formula_name}-${formula_version}"
    mkdir -p "$license_destination"

    copied_license=false
    for license_file in "$cellar_root"/LICENSE* "$cellar_root"/NOTICE* "$cellar_root"/COPYING*; do
        [ -f "$license_file" ] || continue
        cp "$license_file" "$license_destination/"
        copied_license=true
    done
    if [ "$copied_license" = false ]; then
        rmdir "$license_destination"
        echo "warning: no license file found in $cellar_root" >&2
    fi
done < "$license_roots_file"

serf_version="$($source_svn --version | sed -n 's/.*using serf \([0-9][0-9.]*\).*/\1/p' | head -n 1)"
if [ -n "$serf_version" ] && command -v brew >/dev/null 2>&1; then
    serf_source_archive="$(brew --cache --build-from-source apache-serf 2>/dev/null || true)"
    [ -f "$serf_source_archive" ] \
        || fail "Apache Serf source archive is required for licenses; run: brew fetch --build-from-source apache-serf"
    serf_license_destination="$staged_runtime/licenses/apache-serf-$serf_version"
    mkdir -p "$serf_license_destination"
    tar -xOf "$serf_source_archive" "serf-$serf_version/LICENSE" \
        > "$serf_license_destination/LICENSE"
    tar -xOf "$serf_source_archive" "serf-$serf_version/NOTICE" \
        > "$serf_license_destination/NOTICE"
fi

ca_bundle_source="${SVNCLIENT_CA_BUNDLE_PATH:-}"
if [ -z "$ca_bundle_source" ] && command -v brew >/dev/null 2>&1; then
    ca_certificates_prefix="$(brew --prefix ca-certificates 2>/dev/null || true)"
    if [ -n "$ca_certificates_prefix" ]; then
        ca_bundle_source="$ca_certificates_prefix/share/ca-certificates/cacert.pem"
    fi
fi
[ -f "$ca_bundle_source" ] \
    || fail "Mozilla CA bundle was not found; set SVNCLIENT_CA_BUNDLE_PATH to cacert.pem"

mkdir -p "$staged_runtime/etc/ssl"
cp "$ca_bundle_source" "$staged_runtime/etc/ssl/cert.pem"

if [[ "$(realpath "$ca_bundle_source")" =~ ^(/opt/homebrew|/usr/local)/Cellar/ca-certificates/([^/]+)/ ]]; then
    ca_certificates_root="${BASH_REMATCH[1]}/Cellar/ca-certificates/${BASH_REMATCH[2]}"
    ca_license_destination="$staged_runtime/licenses/ca-certificates-${BASH_REMATCH[2]}"
    mkdir -p "$ca_license_destination"
    if [ -f "$ca_certificates_root/sbom.spdx.json" ]; then
        cp "$ca_certificates_root/sbom.spdx.json" "$ca_license_destination/"
    fi
    printf '%s\n' \
        'Mozilla CA certificate store' \
        'License: MPL-2.0' \
        'Source: https://curl.se/docs/caextract.html' \
        > "$ca_license_destination/SOURCE.txt"
fi

for library in "$staged_runtime"/lib/*.dylib; do
    [ -e "$library" ] || continue
    codesign --force --sign - "$library"
done
codesign --force --sign - "$staged_runtime/bin/svn"

svn_version="$($staged_runtime/bin/svn --version --quiet)"
cat > "$staged_runtime/BUILD-INFO.txt" <<EOF
SVN version: $svn_version
Architectures: $(lipo -archs "$staged_runtime/bin/svn")
Packaging method: recursive Homebrew runtime closure with @loader_path relocation
Generated at (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF

(
    cd "$staged_runtime"
    find bin etc lib licenses -type f -print | LC_ALL=C sort | while IFS= read -r packaged_file; do
        shasum -a 256 "$packaged_file"
    done > SHA256SUMS
)

"$script_directory/validate-svn-runtime.sh" "$staged_runtime"

rm -rf \
    "$runtime_directory/bin" \
    "$runtime_directory/etc" \
    "$runtime_directory/lib" \
    "$runtime_directory/licenses"
rm -f \
    "$runtime_directory/BUILD-INFO.txt" \
    "$runtime_directory/SHA256SUMS"

cp -R "$staged_runtime/bin" "$runtime_directory/bin"
cp -R "$staged_runtime/etc" "$runtime_directory/etc"
cp -R "$staged_runtime/lib" "$runtime_directory/lib"
cp -R "$staged_runtime/licenses" "$runtime_directory/licenses"
cp "$staged_runtime/BUILD-INFO.txt" "$runtime_directory/BUILD-INFO.txt"
cp "$staged_runtime/SHA256SUMS" "$runtime_directory/SHA256SUMS"

echo "Packaged SVN $svn_version for arm64 at $runtime_directory"
