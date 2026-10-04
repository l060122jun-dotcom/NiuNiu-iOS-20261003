import Foundation

/// Consume decoded URLSession bytes with a hard application-level body budget.
/// Keep the caller's session (trust, redirect and cookie policies) unchanged.
enum BoundedHTTP {
    static func data(for request: URLRequest, session: URLSession,
                     limit: Int) async throws -> (Data, URLResponse) {
        guard limit > 0 else { throw URLError(.dataLengthExceedsMaximum) }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        var data = Data()
        var chunk = Data()
        chunk.reserveCapacity(32_768)
        for try await byte in bytes {
            // Check before append: even unknown/chunked lengths cannot exceed the budget.
            guard data.count + chunk.count < limit else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            chunk.append(byte)
            if chunk.count == 32_768 {
                try Task.checkCancellation()
                data.append(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        data.append(chunk)
        return (data, response)
    }
}
