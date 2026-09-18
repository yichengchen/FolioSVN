# Word Diff demo

This is an intentionally small feasibility demo. It consumes the existing
`OpenXmlPowerTools-Net6` 4.6.25 package without copying or modifying
`WmlComparer` source code.

## SVN client integration

Run `Scripts/package-worddiff-runtime.sh` before building the macOS application.
Set `WORDDIFF_DOTNET` to an SDK's absolute `dotnet` path if it is not on PATH.
Then run `xcodegen generate`. The generated Xcode project includes
`Vendor/WordDiffRuntime` as resources and signs its executable with JIT entitlement.
The generated runtime is ignored by Git and must be rebuilt on a clean checkout.

For DOCX files, the history window supports selecting two revisions, or selecting
one revision and choosing an external local DOCX. The older/history document is
the original; the newer/local document is the revised input. The client presents
a local HTML content preview in WKWebView, with a button to export the tracked
DOCX. Closing the result window deletes its temporary files.

The HTML preview intentionally omits Word pagination, pictures, numbering,
formatting-only changes and non-body stories. It is not a fidelity renderer.
The engine has a 120-second cancellation timeout. .NET 6 is out of support;
this integration remains a prototype, not a production runtime recommendation.

## Run

The project requires a .NET 6 SDK for development. The published self-contained
binary does not require .NET on the user's computer.

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
  -p:PublishTrimmed=false
```

## Scope

- DOCX input only.
- The package is a third-party MIT-licensed continuation of the archived
  Open XML PowerTools project.
- This demo deliberately has no sandboxing, timeouts, file-size limits, or
  stable production protocol yet.
- Before product integration, test it against representative Chinese documents,
  tables, lists, headers, text boxes, and documents that already contain tracked
  revisions.

See the package page for its license and dependency metadata:
<https://www.nuget.org/packages/OpenXmlPowerTools-Net6/4.6.25>.
