#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
runtime_directory="${1:-$repository_root/Vendor/SVNRuntime}"
svn_executable="$runtime_directory/bin/svn"
ca_bundle="$runtime_directory/etc/ssl/cert.pem"

fail() {
    echo "error: $*" >&2
    exit 1
}

[ -x "$svn_executable" ] || fail "missing executable: $svn_executable"
[ -s "$ca_bundle" ] || fail "missing CA bundle: $ca_bundle"
grep -q -- '-----BEGIN CERTIFICATE-----' "$ca_bundle" || fail "CA bundle contains no certificates"
if grep -q -- '-----BEGIN .*PRIVATE KEY-----' "$ca_bundle"; then
    fail "CA bundle must not contain private keys"
fi

targets=("$svn_executable")
for library in "$runtime_directory"/lib/*.dylib; do
    [ -e "$library" ] || continue
    targets+=("$library")
done

for target in "${targets[@]}"; do
    architectures="$(lipo -archs "$target")"
    case " $architectures " in
        *" arm64 "*) ;;
        *) fail "$(basename "$target") does not contain arm64: $architectures" ;;
    esac

    codesign --verify --strict "$target" \
        || fail "invalid code signature: $target"

    while IFS= read -r dependency; do
        [ -n "$dependency" ] || continue
        case "$dependency" in
            /System/*|/usr/lib/*)
                ;;
            @loader_path/*)
                relative_dependency="${dependency#@loader_path/}"
                [ -f "$(dirname "$target")/$relative_dependency" ] \
                    || fail "missing $dependency required by $target"
                ;;
            *)
                fail "non-relocatable dependency in $target: $dependency"
                ;;
        esac
    done < <(otool -L "$target" | sed '1d' | awk '{print $1}')
done

svn_version="$(env -i PATH=/usr/bin:/bin LANG=C "$svn_executable" --version --quiet)"
[ -n "$svn_version" ] || fail "svn did not report a version"

module_output="$(env -i PATH=/usr/bin:/bin LANG=C "$svn_executable" --version)"
echo "$module_output" | grep -q 'ra_serf' || fail "svn is missing the ra_serf HTTP/HTTPS module"
echo "$module_output" | grep -q "handles 'https' scheme" || fail "svn does not report HTTPS support"

echo "Validated bundled SVN $svn_version ($(lipo -archs "$svn_executable")); ${#targets[@]} Mach-O files"
