import SwiftUI

private struct ActiveAppStateKey: FocusedValueKey {
    typealias Value = AppState
}

extension FocusedValues {
    var activeAppState: AppState? {
        get { self[ActiveAppStateKey.self] }
        set { self[ActiveAppStateKey.self] = newValue }
    }
}
