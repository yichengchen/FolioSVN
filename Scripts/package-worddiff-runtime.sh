#!/bin/bash
set -euo pipefail
script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
dotnet_command="${WORDDIFF_DOTNET:-dotnet}"
"$dotnet_command" publish "$repository_root/Tools/WordDiffDemo/WordDiffDemo.csproj" \
  --configuration Release --runtime osx-arm64 --self-contained true \
  -p:PublishSingleFile=true -p:PublishTrimmed=false \
  --output "$repository_root/Vendor/WordDiffRuntime"
license_directory="$repository_root/Vendor/WordDiffRuntime/licenses"
mkdir -p "$license_directory"
curl -fsSL https://raw.githubusercontent.com/opendocx/Open-Xml-PowerTools/3d541a1403654515130d19db023de5cbc72bf00c/LICENSE -o "$license_directory/OpenXmlPowerTools.txt"
curl -fsSL https://raw.githubusercontent.com/dotnet/Open-XML-SDK/v2.19.0/LICENSE -o "$license_directory/OpenXmlSDK.txt"
curl -fsSL https://raw.githubusercontent.com/dotnet/runtime/v6.0.36/LICENSE.TXT -o "$license_directory/DotNet.txt"
curl -fsSL https://raw.githubusercontent.com/dotnet/runtime/v6.0.36/THIRD-PARTY-NOTICES.TXT -o "$license_directory/DotNet-ThirdParty.txt"
echo "Word diff runtime published to Vendor/WordDiffRuntime"
