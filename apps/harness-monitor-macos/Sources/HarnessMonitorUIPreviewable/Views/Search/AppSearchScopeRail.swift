import HarnessMonitorKit
import SwiftUI

/// Inline scope picker rendered in the session window's content area
/// (below the AppKit window-merge tab strip), shown only while the
/// `.searchable` field is presented.
///
/// `.searchScopes` is intentionally not used: the system places those
/// chips immediately under the search field, which sits above the
/// AppKit tab strip when one is visible. Rendering the picker as a
/// regular `Picker` inside content lets us position it ourselves while
/// keeping native styling.
public struct AppSearchScopeRail: View {
  @Bindable var model: AppSearchModel

  public init(model: AppSearchModel) {
    self.model = model
  }

  public var body: some View {
    if model.isPresented {
      Picker("Search scope", selection: $model.scope) {
        ForEach(AppSearchScope.allCases) { value in
          Text(value.label).tag(value)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.bar)
      .accessibilityIdentifier("app-search.scope-rail")
    }
  }
}
