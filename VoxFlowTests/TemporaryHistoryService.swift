import Foundation
import VoxFlowCore
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

extension HistoryService {
    convenience init(directory: TemporaryDirectory, relativePath: String = "voxflow.sqlite",
                     settings: DictationSettings, keyProvider: @escaping @Sendable () -> any HistoryKeyProviding,
                     clock: any MonotonicClock) {
        self.init(url: directory.file(relativePath), settings: settings, keyProvider: keyProvider, clock: clock,
                  openDatabase: { [directory] url in
            // The database retains this closure until its queue closes; stores may outlive the
            // HistoryService and its wrapper while still keeping the temporary directory alive.
            return try VoxFlowDatabase(url: url, retaining: { withExtendedLifetime(directory) {} })
        })
    }
}
