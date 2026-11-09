import Foundation
import Testing
@testable import MailDigestCore

private func b64(_ svg: String) -> String { Data(svg.utf8).base64EncodedString() }
private let goodSVG = ##"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 10 10"><defs><linearGradient id="g"/></defs><rect fill="url(#g)" width="10" height="10"/><use xlink:href="#g"/></svg>"##

@Suite struct SenderDomainTests {
    @Test func foldsSubdomainsIntoTheMainDomain() {
        #expect(SenderDomain.fold("email.uber.com") == "uber.com")
        #expect(SenderDomain.fold("a.b.c.uber.com") == "uber.com")
        #expect(SenderDomain.fold("Uber.COM.") == "uber.com")
        #expect(SenderDomain.fold("example.uk") == "example.uk")
    }

    @Test func handlesMultiLabelPublicSuffixes() {
        #expect(SenderDomain.fold("mail.qut.edu.au") == "qut.edu.au")
        #expect(SenderDomain.fold("shop.example.com.au") == "example.com.au")
        #expect(SenderDomain.fold("www.bbc.co.uk") == "bbc.co.uk")
        #expect(SenderDomain.fold("x.y.co.nz") == "y.co.nz")
        #expect(SenderDomain.fold("a.example.co.jp") == "example.co.jp")
        #expect(SenderDomain.fold("a.example.net.au") == "example.net.au")
        #expect(SenderDomain.fold("a.example.org.au") == "example.org.au")
        #expect(SenderDomain.fold("a.example.gov.au") == "example.gov.au")
    }

    @Test func bareSuffixOrMalformedGivesNil() {
        for bad in ["com", "co.uk", "edu.au", "", ".", "a..com", "-a.com", "a b.com", "a@b.com", "localhost",
                    "192.168.1.1", "exa_mple.com", String(repeating: "a", count: 64) + ".com"] {
            #expect(SenderDomain.fold(bad) == nil, "\(bad)")
        }
    }

    @Test func extractsTheDomainFromSenderAddressesOnly() {
        #expect(SenderDomain.foldedDomain(fromSender: "Uber <no-reply@email.uber.com>") == "uber.com")
        #expect(SenderDomain.foldedDomain(fromSender: "BOB@Mail.Example.COM") == "example.com")
        #expect(SenderDomain.foldedDomain(fromSender: "example.com") == "example.com") // domain rule entry
        #expect(SenderDomain.foldedDomain(fromSender: "Justin") == nil)
        #expect(SenderDomain.foldedDomain(fromSender: "") == nil)
    }

    @Test func skipsExactlyThePersonalDomains() {
        let personal = ["gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com",
                        "icloud.com", "me.com", "mac.com", "yahoo.com", "proton.me"]
        #expect(SenderDomain.personalDomains == Set(personal))
        for d in personal {
            #expect(SenderDomain.lookupDomain(fromSender: "a@\(d)") == nil, "\(d)")
            #expect(SenderDomain.lookupDomain(fromSender: "a@mail.\(d)") == nil, "mail.\(d)")
        }
        #expect(SenderDomain.lookupDomain(fromSender: "a@email.uber.com") == "uber.com")
        #expect(SenderDomain.lookupDomain(fromSender: "a@protonmail.com") == "protonmail.com")
    }
}

@Suite struct BIMIIndicatorTests {
    @Test func decodesAFoldedHeader() throws {
        let encoded = b64(goodSVG)
        let mid = encoded.index(encoded.startIndex, offsetBy: 20)
        let raw = "Subject: Hi\r\nBIMI-Indicator: \(encoded[..<mid])\r\n \t\(encoded[mid...])\r\nX-Other: 1\r\n\r\nbody"
        let value = try #require(BIMIIndicator.headerValue(inRawHeaders: raw))
        #expect(BIMIIndicator.decodeSVG(headerValue: value) == Data(goodSVG.utf8))
    }

    @Test func headerNameIsCaseInsensitiveAndAbsentIsNil() {
        #expect(BIMIIndicator.headerValue(inRawHeaders: "bimi-indicator: abc\n") == "abc")
        #expect(BIMIIndicator.headerValue(inRawHeaders: "Subject: x\n") == nil)
        // Only the header block counts, never the body.
        #expect(BIMIIndicator.headerValue(inRawHeaders: "Subject: x\n\nBIMI-Indicator: abc") == nil)
    }

    @Test func rejectsNonSVGBadBase64AndOversize() {
        #expect(BIMIIndicator.decodeSVG(headerValue: b64("<html><svg/></html>")) == nil)
        #expect(BIMIIndicator.decodeSVG(headerValue: b64("not an image")) == nil)
        #expect(BIMIIndicator.decodeSVG(headerValue: "!!!not base64!!!") == nil)
        #expect(BIMIIndicator.decodeSVG(headerValue: "") == nil)
        let ok = "<svg xmlns=\"http://www.w3.org/2000/svg\">" + String(repeating: " ", count: SVGSafety.maxBytes - 80) + "</svg>"
        #expect(BIMIIndicator.decodeSVG(headerValue: b64(ok)) != nil)
        let big = "<svg>" + String(repeating: " ", count: SVGSafety.maxBytes) + "</svg>"
        #expect(BIMIIndicator.decodeSVG(headerValue: b64(big)) == nil)
    }

    @Test func acceptsXMLProlog() {
        #expect(SVGSafety.isSafe(Data(("<?xml version=\"1.0\"?>\n<!-- c -->\n" + goodSVG).utf8)))
    }
}

@Suite struct SVGSafetyTests {
    private func wrap(_ inner: String) -> Data { Data("<svg xmlns=\"http://www.w3.org/2000/svg\">\(inner)</svg>".utf8) }

    @Test func acceptsXmlnsAndInternalReferences() {
        #expect(SVGSafety.isSafe(Data(goodSVG.utf8)))
    }

    @Test func rejectsActiveAndExternalContent() {
        let bad = [
            "<script>alert(1)</script>", "<SCRIPT>x</SCRIPT>", "<foreignObject><div/></foreignObject>",
            "<image href=\"#a\"/>", "<rect onload=\"x()\"/>", "<rect onclick = 'x()'/>", "<rect/ onmouseover=x()>",
            "<use href=\"https://evil.example/a.svg#x\"/>", "<use xlink:href=\"http://evil.example/a\"/>",
            "<a href=\"javascript:alert(1)\"/>", "<use href=\"//evil.example/x\"/>", "<use href=\"data:image/svg+xml,x\"/>",
            "<rect fill=\"url(https://evil.example/x)\"/>", "<rect style=\"fill:url( 'http://evil.example/x' )\"/>",
            "<style>@import url(https://evil.example/x.css);</style>", "<style>r{fill:u\\72l(http://e/x)}</style>",
            "<set attributeName=\"href\" to=\"https://e\"/>", "<animate attributeName=\"href\" values=\"https://e\"/>",
            "<iframe src=\"https://e\"/>", "<rect fill=\"&#117;rl(http://e)\"/>",
        ]
        for inner in bad { #expect(!SVGSafety.isSafe(wrap(inner)), "\(inner)") }
    }

    @Test func rejectsEntityTricksAndNonSVG() {
        #expect(!SVGSafety.isSafe(Data("<!DOCTYPE svg [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><svg>&x;</svg>".utf8)))
        #expect(!SVGSafety.isSafe(Data("<?xml-stylesheet href=\"x.css\"?><svg/>".utf8)))
        #expect(!SVGSafety.isSafe(Data("<svgfoo/>".utf8)))
        #expect(!SVGSafety.isSafe(Data()))
        #expect(!SVGSafety.isSafe(Data([0xff, 0xfe, 0x00])))
    }
}

@Suite struct BIMIRecordTests {
    @Test func takesTheHTTPSLocation() {
        #expect(BIMIRecord.logoURL(fromTXT: "v=BIMI1; l=https://example.com/logo.svg; a=https://example.com/v.pem;")?.absoluteString
            == "https://example.com/logo.svg")
        #expect(BIMIRecord.logoURL(fromTXT: " V=bimi1 ;L=https://cdn.example.com/a.svg")?.host == "cdn.example.com")
    }

    @Test func rejectsEverythingElse() {
        for txt in ["v=BIMI1; l=;", "v=BIMI1; l=http://example.com/a.svg;", "v=BIMI1;", "l=https://example.com/a.svg",
                    "v=DKIM1; l=https://example.com/a.svg", "v=BIMI1; l=ftp://example.com/a.svg", "",
                    "v=BIMI1; l=https://127.0.0.1/a.svg", "v=BIMI1; l=https://localhost/a.svg",
                    "v=BIMI1; l=https://user:pw@example.com/a.svg", "v=BIMI1; l=https://example.com:8443/a.svg",
                    "v=BIMI1; l=https://printer.local/a.svg", "v=BIMI1; l=https://[::1]/a.svg", "v=BIMI1; l=not a url"] {
            #expect(BIMIRecord.logoURL(fromTXT: txt) == nil, "\(txt)")
        }
    }
}

// MARK: Cache and service

private actor FakeStore: SenderLogoStore {
    private(set) var records: [String: LogoRecord] = [:]
    func record(domain: String, origin: LogoOrigin) async -> LogoRecord? { records["\(origin.rawValue)/\(domain)"] }
    func save(_ record: LogoRecord) async { records["\(record.origin.rawValue)/\(record.domain)"] = record }
}

private actor FakeFetcher: SenderLogoFetching {
    private(set) var domains: [String] = []
    var result: SenderLogo?
    var delay: Duration = .zero
    init(result: SenderLogo? = SenderLogo(format: .png, data: Data([1, 2, 3]))) { self.result = result }
    func setResult(_ r: SenderLogo?) { result = r }
    func setDelay(_ d: Duration) { delay = d }
    func fetchLogo(forDomain domain: String) async -> SenderLogo? {
        domains.append(domain)
        if delay > .zero { try? await Task.sleep(for: delay) }
        return result
    }
}

@Suite struct SenderLogoCacheTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    @Test func policyIsThirtyDays() {
        #expect(LogoCachePolicy.isLive(fetchedAt: t0, now: t0))
        #expect(LogoCachePolicy.isLive(fetchedAt: t0, now: t0.addingTimeInterval(30 * day - 1)))
        #expect(!LogoCachePolicy.isLive(fetchedAt: t0, now: t0.addingTimeInterval(30 * day)))
        #expect(!LogoCachePolicy.isLive(fetchedAt: t0.addingTimeInterval(10), now: t0))
    }

    @Test func fetchesOnceThenServesFromCacheUntilExpiry() async {
        let clock = FixedClock(t0), store = FakeStore(), fetcher = FakeFetcher()
        let service = SenderLogoService(store: store, fetcher: fetcher, clock: clock)
        let first = await service.networkLogo(forSender: "A <a@email.uber.com>", enabled: true)
        let second = await service.networkLogo(forSender: "b@uber.com", enabled: true)
        #expect(first != nil && first == second)
        #expect(await fetcher.domains == ["uber.com"])
        clock.advance(by: 30 * day - 1)
        _ = await service.networkLogo(forSender: "b@uber.com", enabled: true)
        #expect(await fetcher.domains.count == 1)
        clock.advance(by: 2)
        _ = await service.networkLogo(forSender: "b@uber.com", enabled: true)
        #expect(await fetcher.domains.count == 2)
    }

    @Test func failuresAreCachedToo() async {
        let clock = FixedClock(t0), store = FakeStore(), fetcher = FakeFetcher(result: nil)
        let service = SenderLogoService(store: store, fetcher: fetcher, clock: clock)
        #expect(await service.networkLogo(forSender: "a@nope.example", enabled: true) == nil)
        #expect(await service.networkLogo(forSender: "a@nope.example", enabled: true) == nil)
        #expect(await fetcher.domains == ["nope.example"])
        let saved = await store.records["network/nope.example"]
        #expect(saved != nil && saved?.logo == nil && saved?.fetchedAt == t0)
        clock.advance(by: 31 * day)
        await fetcher.setResult(SenderLogo(format: .svg, data: Data("x".utf8)))
        #expect(await service.networkLogo(forSender: "a@nope.example", enabled: true)?.format == .svg)
        #expect(await fetcher.domains.count == 2)
    }

    @Test func concurrentCallersShareOneRequest() async {
        let clock = FixedClock(t0), fetcher = FakeFetcher()
        await fetcher.setDelay(.milliseconds(50))
        let service = SenderLogoService(store: FakeStore(), fetcher: fetcher, clock: clock)
        await withTaskGroup(of: SenderLogo?.self) { group in
            for i in 0..<12 {
                group.addTask { await service.networkLogo(forSender: "n\(i)@news.example.com", enabled: true) }
            }
            for await logo in group { #expect(logo != nil) }
        }
        #expect(await fetcher.domains == ["example.com"])
    }

    @Test func neverFetchesWhenOffPersonalOrWithoutADomain() async {
        let fetcher = FakeFetcher()
        let service = SenderLogoService(store: FakeStore(), fetcher: fetcher, clock: FixedClock(t0))
        #expect(await service.networkLogo(forSender: "a@uber.com", enabled: false) == nil)
        #expect(await service.networkLogo(forSender: "a@gmail.com", enabled: true) == nil)
        #expect(await service.networkLogo(forSender: "a@mail.yahoo.com", enabled: true) == nil)
        #expect(await service.networkLogo(forSender: "no address", enabled: true) == nil)
        #expect(await fetcher.domains.isEmpty)
    }

    @Test func cachedNetworkLogoIsNotReturnedWhenSettingTurnsOff() async {
        let service = SenderLogoService(store: FakeStore(), fetcher: FakeFetcher(), clock: FixedClock(t0))
        #expect(await service.logo(forSender: "a@uber.com", networkEnabled: true) != nil)
        #expect(await service.logo(forSender: "a@uber.com", networkEnabled: false) == nil)
    }

    @Test func headerLogoWinsAndShowsWithTheSettingOff() async {
        let fetcher = FakeFetcher()
        let service = SenderLogoService(store: FakeStore(), fetcher: fetcher, clock: FixedClock(t0))
        await service.recordBIMIHeader(b64(goodSVG), sender: "Uber <x@email.uber.com>")
        let off = await service.logo(forSender: "y@uber.com", networkEnabled: false)
        #expect(off == SenderLogo(format: .svg, data: Data(goodSVG.utf8)))
        let on = await service.logo(forSender: "y@uber.com", networkEnabled: true)
        #expect(on == off)
        #expect(await fetcher.domains.isEmpty)
    }

    @Test func unsafeOrPersonalHeadersAreNotStored() async {
        let store = FakeStore()
        let service = SenderLogoService(store: store, fetcher: FakeFetcher(), clock: FixedClock(t0))
        await service.recordBIMIHeader(b64("<svg><script/></svg>"), sender: "a@evil.example")
        await service.recordBIMIHeader(b64(goodSVG), sender: "a@gmail.com")
        await service.recordBIMIHeader("garbage", sender: "a@evil.example")
        #expect(await store.records.isEmpty)
    }

    @Test func decodesBIMIHeaderFromJXAJSON() throws {
        let raw = "Subject: x\\nBIMI-Indicator: \(b64(goodSVG))\\n"
        let json = #"{"id":"i@x","account":"a","mailbox":"m","sender":"s <s@x.com>","subject":"t","receivedAt":"2026-01-01T00:00:00Z","body":"b","rawHeaders":"\#(raw)"}"#
        let message = try MailJSONDecoder().decodeMessage(Data(json.utf8))
        #expect(message.bimiIndicator == b64(goodSVG))
        // The value is transient: never encoded.
        let encoded = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        #expect(!encoded.contains("bimi") && !encoded.contains(b64(goodSVG)))
    }
}
