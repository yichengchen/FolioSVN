using System.Text.Json;
using System.Net;
using System.Xml.Linq;
using DocumentFormat.OpenXml;
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Wordprocessing;
using OpenXmlPowerTools;

return await WordDiffDemoApp.RunAsync(args);

internal static class WordDiffDemoApp
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false,
    };

    public static Task<int> RunAsync(string[] args)
    {
        if (args.Length == 0 || args[0] is "-h" or "--help")
        {
            PrintUsage();
            return Task.FromResult(0);
        }

        return Task.FromResult(args[0] switch
        {
            "compare" => Compare(args[1..]),
            "make-samples" => MakeSamples(args[1..]),
            _ => Fail(2, "unknown_command", $"Unknown command: {args[0]}"),
        });
    }

    private static int Compare(string[] args)
    {
        var positional = args.Where(argument => !argument.StartsWith("--author=", StringComparison.Ordinal)).ToArray();
        var author = args
            .FirstOrDefault(argument => argument.StartsWith("--author=", StringComparison.Ordinal))?
            .Substring("--author=".Length) ?? "Folio SVN";

        if (positional.Length != 3)
        {
            return Fail(2, "invalid_arguments", "compare requires ORIGINAL.(doc|docx) REVISED.(doc|docx) OUTPUT.docx");
        }

        var originalPath = Path.GetFullPath(positional[0]);
        var revisedPath = Path.GetFullPath(positional[1]);
        var outputPath = Path.GetFullPath(positional[2]);

        if (!IsSupportedWordPath(originalPath) || !IsSupportedWordPath(revisedPath))
        {
            return Fail(2, "unsupported_format", "Only .doc and .docx inputs are supported");
        }

        if (!File.Exists(originalPath))
        {
            return Fail(3, "input_not_found", $"Original document does not exist: {originalPath}");
        }

        if (!File.Exists(revisedPath))
        {
            return Fail(3, "input_not_found", $"Revised document does not exist: {revisedPath}");
        }

        try
        {
            var outputDirectory = Path.GetDirectoryName(outputPath);
            if (!string.IsNullOrEmpty(outputDirectory))
            {
                Directory.CreateDirectory(outputDirectory);
            }

            var settings = new WmlComparerSettings
            {
                AuthorForRevisions = author,
                DetailThreshold = 0,
            };

            var textMode = IsLegacyDoc(originalPath) || IsLegacyDoc(revisedPath);
            using var normalized = textMode ? NormalizeForTextComparison(originalPath, revisedPath) : null;
            var comparisonOriginalPath = normalized?.OriginalPath ?? originalPath;
            var comparisonRevisedPath = normalized?.RevisedPath ?? revisedPath;
            var original = new WmlDocument(comparisonOriginalPath);
            var revised = new WmlDocument(comparisonRevisedPath);
            var compared = WmlComparer.Compare(original, revised, settings);
            compared.SaveAs(outputPath);
            var htmlPath = Path.ChangeExtension(outputPath, ".html");
            WriteHtml(outputPath, htmlPath, textMode);

            var revisionCount = WmlComparer.GetRevisions(compared, settings).Count();
            WriteJson(new
            {
                status = "success",
                outputPath,
                htmlPath,
                revisionCount,
                comparisonMode = textMode ? "text" : "document",
            });
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception);
            return Fail(4, "comparison_failed", exception.Message);
        }
    }

    private static int MakeSamples(string[] args)
    {
        if (args.Length != 1)
        {
            return Fail(2, "invalid_arguments", "make-samples requires OUTPUT_DIRECTORY");
        }

        try
        {
            var outputDirectory = Path.GetFullPath(args[0]);
            Directory.CreateDirectory(outputDirectory);

            var originalPath = Path.Combine(outputDirectory, "original.docx");
            var revisedPath = Path.Combine(outputDirectory, "revised.docx");
            CreateDocument(originalPath, "合同金额为 100 万元。", "交付日期为 2026 年 9 月 30 日。");
            CreateDocument(revisedPath, "合同金额为 120 万元。", "交付日期为 2026 年 10 月 15 日。", "新增：验收后七日内付款。");

            WriteJson(new
            {
                status = "success",
                originalPath,
                revisedPath,
            });
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception);
            return Fail(4, "sample_creation_failed", exception.Message);
        }
    }

    // A deliberately simple local preview, not a Word layout renderer.
    // Only emitted markup is used; input URLs, scripts and relationships are never followed.
    private static bool IsSupportedWordPath(string path) =>
        Path.GetExtension(path).Equals(".doc", StringComparison.OrdinalIgnoreCase) ||
        Path.GetExtension(path).Equals(".docx", StringComparison.OrdinalIgnoreCase);

    private static bool IsLegacyDoc(string path) =>
        Path.GetExtension(path).Equals(".doc", StringComparison.OrdinalIgnoreCase);

    private static NormalizedDocuments NormalizeForTextComparison(string originalPath, string revisedPath)
    {
        var directory = Path.Combine(Path.GetTempPath(), "folio-worddiff-normalized-" + Guid.NewGuid());
        Directory.CreateDirectory(directory);
        try
        {
            var original = Path.Combine(directory, "original.docx");
            var revised = Path.Combine(directory, "revised.docx");
            CreateDocument(original, ExtractParagraphs(originalPath));
            CreateDocument(revised, ExtractParagraphs(revisedPath));
            return new NormalizedDocuments(directory, original, revised);
        }
        catch
        {
            Directory.Delete(directory, true);
            throw;
        }
    }

    private static string[] ExtractParagraphs(string path)
    {
        string text;
        if (IsLegacyDoc(path))
        {
            text = LegacyDocTextExtractor.Extract(path);
        }
        else
        {
            using var document = WordprocessingDocument.Open(path, false);
            text = string.Join("\n", document.MainDocumentPart?.Document.Body?
                .Descendants<Paragraph>().Select(paragraph => paragraph.InnerText) ?? Array.Empty<string>());
        }
        text = text.Replace('\u0007', '\t').Replace('\v', '\n').Replace('\f', '\n').Replace("\r\n", "\n").Replace('\r', '\n');
        return text.Split('\n', StringSplitOptions.None);
    }

    private sealed class NormalizedDocuments : IDisposable
    {
        public string OriginalPath { get; }
        public string RevisedPath { get; }
        private readonly string directory;

        public NormalizedDocuments(string directory, string originalPath, string revisedPath) =>
            (this.directory, OriginalPath, RevisedPath) = (directory, originalPath, revisedPath);

        public void Dispose()
        {
            try { Directory.Delete(directory, true); } catch { }
        }
    }

    private static void WriteHtml(string documentPath, string htmlPath, bool textMode)
    {
        using var document = WordprocessingDocument.Open(documentPath, false);
        using var stream = document.MainDocumentPart!.GetStream();
        var xml = XDocument.Load(stream);
        XNamespace w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
        string Render(XElement element)
        {
            if (element.Name.Namespace != w) return "";
            var children = string.Concat(element.Elements().Select(Render));
            return element.Name.LocalName switch
            {
                "t" or "delText" => WebUtility.HtmlEncode(element.Value),
                "p" => "<p>" + children + "</p>",
                "tbl" => "<table>" + children + "</table>",
                "tr" => "<tr>" + children + "</tr>",
                "tc" => "<td>" + children + "</td>",
                "ins" or "moveTo" => "<ins>" + children + "</ins>",
                "del" or "moveFrom" => "<del>" + children + "</del>",
                "tab" => "&#9;",
                "br" or "cr" => "<br>",
                "drawing" or "pict" or "object" => "<span class='note'>[图片/对象]</span>",
                "pPr" or "rPr" or "tblPr" or "trPr" or "tcPr" or "sectPr" => "",
                _ => children,
            };
        }
        var body = xml.Root!.Element(w + "body")!;
        var html = "<!doctype html><html lang='zh-CN'><meta charset='utf-8'>" +
            "<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; style-src 'unsafe-inline'\">" +
            "<title>Word 版本比较</title><style>" +
            "body{font:16px -apple-system,sans-serif;max-width:1000px;margin:32px auto;padding:0 24px;color:#222}" +
            "p{white-space:pre-wrap;line-height:1.7;min-height:1em}ins{background:#d9f5df;color:#146b2d}" +
            "del{background:#ffe1e1;color:#a12222}table{border-collapse:collapse;width:100%}" +
            "td{border:1px solid #ccc;padding:8px;vertical-align:top}.note{color:#666;font-size:13px}" +
            "</style><body><h2>Word 版本比较</h2>" +
            "<p class='note'>绿色：新增 · 红色删除线：删除。" +
            (textMode ? "由于输入包含旧版 DOC，本次只比较正文文本；" : "") +
            "简化内容预览不还原原始分页、图片、编号和格式；页眉页脚等不在此预览中。详细修订可导出 DOCX。</p>" +
            Render(body) + "</body></html>";
        File.WriteAllText(htmlPath, html);
    }

    private static void CreateDocument(string path, params string[] paragraphs)
    {
        using var document = WordprocessingDocument.Create(path, WordprocessingDocumentType.Document);
        var mainPart = document.AddMainDocumentPart();
        var stylesPart = mainPart.AddNewPart<StyleDefinitionsPart>();
        stylesPart.Styles = new Styles(
            new Style(
                new StyleName { Val = "Normal" })
            {
                Type = StyleValues.Paragraph,
                StyleId = "Normal",
                Default = true,
            });
        stylesPart.Styles.Save();

        var body = new Body();
        foreach (var text in paragraphs)
        {
            body.AppendChild(new Paragraph(new Run(new Text(text))));
        }

        body.AppendChild(new SectionProperties());
        mainPart.Document = new Document(body);
        mainPart.Document.Save();
    }

    private static int Fail(int exitCode, string code, string message)
    {
        WriteJson(new { status = "error", code, message });
        return exitCode;
    }

    private static void WriteJson(object value) => Console.WriteLine(JsonSerializer.Serialize(value, JsonOptions));

    private static void PrintUsage()
    {
        Console.WriteLine(
            "worddiff-demo compare ORIGINAL.(doc|docx) REVISED.(doc|docx) OUTPUT.docx [--author=NAME]\n" +
            "worddiff-demo make-samples OUTPUT_DIRECTORY");
    }
}
