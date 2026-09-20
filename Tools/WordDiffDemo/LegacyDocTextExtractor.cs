using System.Text;
using NPOI.HWPF.Extractor;

internal static class LegacyDocTextExtractor
{
    private const long MaxInputBytes = 256L * 1024 * 1024;

    static LegacyDocTextExtractor() => Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

    public static string Extract(string path)
    {
        if (new FileInfo(path).Length > MaxInputBytes)
        {
            throw new InvalidDataException("DOC 文件超过 256 MB，无法安全处理。");
        }

        using var stream = File.OpenRead(path);
        var extractor = new WordExtractor(stream);
        return string.Concat(extractor.ParagraphText);
    }
}
