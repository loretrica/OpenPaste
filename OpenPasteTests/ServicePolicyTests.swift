import Foundation
import Testing
@testable import OpenPaste

struct ServicePolicyTests {
    @Test
    func metadataParserNormalizesTitleAndDescription() {
        let html = """
        <html><head>
        <title>  Hello&nbsp; <b>world</b> &amp; all </title>
        <meta content='A &quot;useful&quot; page' property='og:description'>
        </head></html>
        """

        #expect(HTMLMetadataParser.parse(html) == ClipboardLinkMetadata(
            title: "Hello world & all",
            description: "A \"useful\" page"))
    }

    @Test
    func metadataParserReturnsNilWhenPageHasNoUsableMetadata() {
        #expect(HTMLMetadataParser.parse("<html><title>  </title></html>") == nil)
    }

    @Test
    func metadataURLPolicyRejectsNonWebAndLocalAddresses() throws {
        let deniedURLs = [
            "file:///etc/passwd",
            "http://localhost",
            "https://printer.local",
            "http://10.0.0.8",
            "http://172.16.2.4",
            "http://192.168.1.4",
            "http://[fd00::1]"
        ]
        for value in deniedURLs {
            let url = try #require(URL(string: value))
            #expect(!MetadataURLPolicy.allows(url), "Unexpectedly allowed \(value)")
        }
        #expect(MetadataURLPolicy.allows(try #require(URL(string: "https://example.com/path"))))
    }

    @Test
    func clipboardTextNormalizerRejectsWhitespaceButPreservesOriginalText() {
        #expect(ClipboardTextNormalizer.acceptedContent(nil) == nil)
        #expect(ClipboardTextNormalizer.acceptedContent(" \n\t ") == nil)
        #expect(ClipboardTextNormalizer.acceptedContent("  copied text\n") == "  copied text\n")
    }
}
