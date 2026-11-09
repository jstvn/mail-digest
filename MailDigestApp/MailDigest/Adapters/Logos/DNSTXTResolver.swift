import dnssd
import Foundation

/// Reads TXT records with the system resolver (`DNSServiceQueryRecord`), since Foundation has no TXT lookup.
/// Only ever asked for `default._bimi.<domain>`. Gives up after `timeout`.
struct DNSTXTResolver: Sendable {
    var timeout: TimeInterval = 4

    /// One string per TXT record (the record's character-strings joined), empty on any failure.
    func txtRecords(for name: String) async -> [String] {
        await withCheckedContinuation { continuation in
            let query = Query(continuation: continuation)
            query.start(name: name, timeout: timeout)
        }
    }

    /// One in-flight query. Everything runs on its own serial queue, which also receives the callback.
    private final class Query: @unchecked Sendable {
        private let queue = DispatchQueue(label: "MailDigest.dns-txt")
        private var continuation: CheckedContinuation<[String], Never>?
        private var ref: DNSServiceRef?
        private var records: [String] = []

        init(continuation: CheckedContinuation<[String], Never>) { self.continuation = continuation }

        func start(name: String, timeout: TimeInterval) {
            queue.async {
                // The callback gets an unretained pointer; `finish` balances this retain.
                let context = Unmanaged.passRetained(self).toOpaque()
                var newRef: DNSServiceRef?
                let flags = DNSServiceFlags(kDNSServiceFlagsReturnIntermediates | kDNSServiceFlagsTimeout)
                let status = DNSServiceQueryRecord(&newRef, flags, 0, name, UInt16(kDNSServiceType_TXT),
                                                   UInt16(kDNSServiceClass_IN), Self.callback, context)
                guard status == kDNSServiceErr_NoError, let newRef else {
                    self.finish(retained: true)
                    return
                }
                self.ref = newRef
                DNSServiceSetDispatchQueue(newRef, self.queue)
                self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(retained: true) }
            }
        }

        private static let callback: DNSServiceQueryRecordReply = { _, flags, _, errorCode, _, _, _, rdlen, rdata, _, context in
            guard let context else { return }
            let query = Unmanaged<Query>.fromOpaque(context).takeUnretainedValue()
            if errorCode != kDNSServiceErr_NoError { query.finish(retained: true); return }
            if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let rdata {
                query.records.append(Query.joinedStrings(UnsafeBufferPointer(start: rdata.assumingMemoryBound(to: UInt8.self),
                                                                          count: Int(rdlen))))
            }
            if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 { query.finish(retained: true) }
        }

        /// TXT rdata is a run of length-prefixed strings; BIMI wants them joined.
        private static func joinedStrings(_ bytes: UnsafeBufferPointer<UInt8>) -> String {
            var out = Data()
            var i = 0
            while i < bytes.count {
                let length = Int(bytes[i])
                i += 1
                let end = min(i + length, bytes.count)
                out.append(contentsOf: bytes[i..<end])
                i = end
            }
            return String(decoding: out, as: UTF8.self)
        }

        /// Completes once; later calls (a timeout after an answer) do nothing. Runs on `queue`.
        private func finish(retained: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            if let ref { DNSServiceRefDeallocate(ref); self.ref = nil }
            if retained { Unmanaged.passUnretained(self).release() }
            continuation.resume(returning: records)
        }
    }
}
