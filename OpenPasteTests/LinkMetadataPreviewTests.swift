import Foundation
import Testing
@testable import OpenPaste

struct LinkMetadataPreviewTests {
    @Test
    func relativeOpenGraphImageUsesPageURL() throws {
        let html = #"<meta property='og:image' content='../media/cover.png?x=1&amp;y=2'><meta property='og:title' content='A &amp; B'>"#
        let metadata = try #require(HTMLMetadataParser.parse(
            html, baseURL: URL(string: "https://example.com/articles/story")))
        #expect(metadata.title == "A & B")
        #expect(metadata.imageURL == "https://example.com/media/cover.png?x=1&y=2")
    }

    @Test
    func thumbnailDoesNotAcceptPrivateOrNonWebURLs() {
        for address in ["http://localhost/cover.png", "http://192.168.0.2/cover.png", "file:///tmp/cover.png"] {
            let metadata = HTMLMetadataParser.parse(
                "<title>Saved page</title><meta property='og:image' content='" + address + "'>")
            #expect(metadata?.imageURL == nil)
            #expect(metadata?.title == "Saved page")
        }
    }

    @Test
    func twitterImageIsUsedWhenOpenGraphIsMissing() {
        let metadata = HTMLMetadataParser.parse(
            #"<meta name="twitter:image" content="https://example.com/cover.jpg">"#)
        #expect(metadata?.imageURL == "https://example.com/cover.jpg")
    }
}
