import HarnessMonitorKit
import SwiftUI

struct WorkspaceSidebarGenericSearchContainer<Content: View>: View {
  let content: Content
  @Binding var searchText: String
  @Binding var searchPresentation: Bool
  let prompt: Text

  var body: some View {
    content
      .listStyle(.sidebar)
      .scrollEdgeEffectStyle(.soft, for: .top)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .searchable(
        text: $searchText,
        isPresented: $searchPresentation,
        placement: .sidebar,
        prompt: prompt
      )
  }
}

struct WorkspaceSidebarDecisionSearchContainer<Content: View>: View {
  let content: Content
  @Binding var searchText: String
  @Binding var searchPresentation: Bool
  let decisionSearchScope: Binding<DecisionsSidebarSearchScope>
  let prompt: Text

  var body: some View {
    content
      .listStyle(.sidebar)
      .scrollEdgeEffectStyle(.soft, for: .top)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .searchable(
        text: $searchText,
        isPresented: $searchPresentation,
        placement: .sidebar,
        prompt: prompt
      )
      .searchScopes(decisionSearchScope, activation: .onSearchPresentation) {
        ForEach(DecisionsSidebarSearchScope.allCases) { scope in
          Text(scope.label).tag(scope)
        }
      }
  }
}
