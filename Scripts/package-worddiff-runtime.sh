#!/bin/bash
set -euo pipefail
script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
dotnet_command="${WORDDIFF_DOTNET:-dotnet}"
runtime_directory="$repository_root/Vendor/WordDiffRuntime"
work_directory="$(mktemp -d "${TMPDIR:-/tmp}/folio-worddiff-package.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT
staged_runtime="$work_directory/runtime"

"$dotnet_command" publish "$repository_root/Tools/WordDiffDemo/WordDiffDemo.csproj" \
  --configuration Release --runtime osx-arm64 --self-contained true \
  -p:PublishSingleFile=true -p:PublishTrimmed=false \
  -p:EnableCompressionInSingleFile=true \
  -p:RestoreLockedMode=true \
  --output "$staged_runtime"

license_directory="$staged_runtime/licenses"
mkdir -p "$license_directory"
curl -fsSL https://raw.githubusercontent.com/opendocx/Open-Xml-PowerTools/3d541a1403654515130d19db023de5cbc72bf00c/LICENSE -o "$license_directory/OpenXmlPowerTools.txt"
curl -fsSL https://raw.githubusercontent.com/dotnet/Open-XML-SDK/v2.19.0/LICENSE -o "$license_directory/OpenXmlSDK.txt"
curl -fsSL https://raw.githubusercontent.com/IS4Code/npoi/7987ec8b88225b4cc6fbe2db661be70b2c4323ea/LICENSE -o "$license_directory/NPOI-HWPF.txt"
curl -fsSL https://raw.githubusercontent.com/nissl-lab/npoi/5b864945b1c54b3421d256ee7424209958ebade4/LICENSE -o "$license_directory/NPOI.txt"
curl -fsSL https://raw.githubusercontent.com/dotnet/runtime/v10.0.12/LICENSE.TXT -o "$license_directory/DotNet.txt"
curl -fsSL https://raw.githubusercontent.com/dotnet/runtime/v10.0.12/THIRD-PARTY-NOTICES.TXT -o "$license_directory/DotNet-ThirdParty.txt"

assets_file="$repository_root/Tools/WordDiffDemo/obj/project.assets.json"
package_root="$(jq -r '.packageFolders | keys[0]' "$assets_file")"
while IFS=/ read -r package_id package_version; do
  lowercase_package_id="$(printf '%s' "$package_id" | tr '[:upper:]' '[:lower:]')"
  package_directory="$package_root/$lowercase_package_id/$package_version"
  package_license_directory="$license_directory/nuget/$package_id-$package_version"
  mkdir -p "$package_license_directory"
  find "$package_directory" -maxdepth 2 -type f \
    \( -iname 'license*' -o -iname 'notice*' -o -iname '*third-party*' -o -iname '*.nuspec' \) \
    -exec cp {} "$package_license_directory"/ \;
done < <(jq -r '.libraries | to_entries[] | select(.value.type == "package") | .key' "$assets_file")

mkdir -p "$runtime_directory"
find "$runtime_directory" -mindepth 1 -maxdepth 1 ! -name .gitkeep -exec rm -rf {} +
cp -R "$staged_runtime"/. "$runtime_directory"/
echo "Word diff runtime published to Vendor/WordDiffRuntime"
