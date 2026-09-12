import Foundation

protocol SentRequestMetrics {
    var countOfRequestHeaderBytesSent: Int64 { get }
    var countOfRequestBodyBytesSent: Int64 { get }
    var resourceFetchType: URLSessionTaskMetrics.ResourceFetchType { get }
}

extension URLSessionTaskTransactionMetrics: SentRequestMetrics {}

/// Per-task delegate includes every redirect transaction and collects metrics even when a task
/// fails or is cancelled. The value-only protocol lets unit tests exercise accounting offline.
final class ModelRequestMetricsDelegate: NSObject, URLSessionTaskDelegate {
    private let counter: ModelRequestByteCounter
    init(counter: ModelRequestByteCounter) { self.counter = counter }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        recordTransactions(metrics.transactionMetrics)
    }

    func recordTransactions(_ transactions: [any SentRequestMetrics]) {
        // Unknown fetch classifications can still report bytes sent before failure. Preserve
        // those measurements; only cache-only transactions are deliberately excluded.
        for transaction in transactions where transaction.resourceFetchType != .localCache {
            counter.record(headerBytes: transaction.countOfRequestHeaderBytesSent,
                           bodyBytes: transaction.countOfRequestBodyBytesSent)
        }
    }
}
