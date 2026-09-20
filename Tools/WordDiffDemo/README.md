# Word Diff demo

This is an intentionally small feasibility demo. It consumes the existing
`OpenXmlPowerTools-Net6` 4.6.25 package without copying or modifying
`WmlComparer` source code.

## SVN client integration

Run `Scripts/package-worddiff-runtime.sh` before building the macOS application.
Set `WORDDIFF_DOTNET` to an SDK's absolute `dotnet` path if it is not on PATH.
Then run `xcodegen generate`. The generated Xcode project includes
`Vendor/WordDiffRuntime` as resources and signs its .NET executable.
The generated runtime is ignored by Git and must be rebuilt on a clean checkout.

For DOC and DOCX files, the history window supports selecting two revisions, or selecting
one revision and choosing an external local Word file. The older/history document is
the original; the newer/local document is the revised input. The client presents
a local HTML content preview in WKWebView, with a button to export the tracked
DOCX. Closing the result window deletes its temporary files.

DOCX-to-DOCX comparisons use WmlComparer directly. When either input is a legacy
DOC, the pure-.NET `ScratchPad.NPOI.HWPF` package extracts both documents to
normalized body text before comparison. It does not require Java, Word or
LibreOffice on the user's computer.

The HTML preview intentionally omits Word pagination, pictures, numbering,
formatting-only changes and non-body stories. It is not a fidelity renderer.
The engine has a 120-second cancellation timeout. The helper targets the
supported .NET 10 LTS runtime.

## Run

The project requires a .NET 10 SDK for development. The published self-contained
runtime does not require .NET or Java on the user's computer.

```bash
dotnet restore Tools/WordDiffDemo/WordDiffDemo.csproj
dotnet run --project Tools/WordDiffDemo -- make-samples /tmp/worddiff-samples
dotnet run --project Tools/WordDiffDemo -- compare \
  /tmp/worddiff-samples/original.docx \
  /tmp/worddiff-samples/revised.docx \
  /tmp/worddiff-samples/compared.docx
```

Both commands write a single JSON object to standard output. A successful
comparison reports the number of revisions and writes a DOCX containing Word
tracked-change markup.

## Publish for Apple Silicon

```bash
dotnet publish Tools/WordDiffDemo/WordDiffDemo.csproj \
  --configuration Release \
  --runtime osx-arm64 \
  --self-contained true \
  -p:PublishSingleFile=true \
  -p:PublishTrimmed=false \
  -p:EnableCompressionInSingleFile=true
```

## Scope

- DOCX inputs receive document-level comparison. DOC inputs receive body-text-only
  comparison through Apache POI HWPF; formatting, pictures, text boxes, headers,
  footers and comments are not preserved.
- The package is a third-party MIT-licensed continuation of the archived
  Open XML PowerTools project.
- `ScratchPad.NPOI.HWPF` 2.5.7 is a third-party netstandard2.0 package of NPOI's
  HWPF scratchpad source and is binary-bound to the Apache-2.0 NPOI 2.5.6 core.
  Current official NPOI packages still do not include HWPF and are not binary
  compatible with this scratchpad assembly.
- The helper rejects DOC inputs over 256 MB, and the client applies a 120-second
  timeout. Document parsing is not otherwise sandboxed.
- Before product integration, test it against representative Chinese documents,
  tables, lists, headers, text boxes, and documents that already contain tracked
  revisions.

See the package page for its license and dependency metadata:
<https://www.nuget.org/packages/OpenXmlPowerTools-Net6/4.6.25>.
