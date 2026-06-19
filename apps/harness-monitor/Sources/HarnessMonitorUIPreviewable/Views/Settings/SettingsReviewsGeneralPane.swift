import HarnessMonitorKit
import SwiftUI

struct SettingsReviewsGeneralPane: View {
  let isActive: Bool
  @Binding var draft: DashboardReviewsPreferences
  @Binding var navigationRequest: SettingsNavigationRequest?
  @State private var slaIsCustom = false
  @State private var slaCustomAmount: Int = 2
  @State private var slaCustomUnit: SLADurationUnit = .days

  init(
    draft: Binding<DashboardReviewsPreferences>,
    navigationRequest: Binding<SettingsNavigationRequest?> = .constant(nil),
    isActive: Bool = true
  ) {
    self.isActive = isActive
    _draft = draft
    _navigationRequest = navigationRequest
    let hours = draft.wrappedValue.slaThresholdHours
    let startsCustom = hours != nil && !Self.slaPresets.contains(where: { $0.hours == hours })
    _slaIsCustom = State(initialValue: startsCustom)
    if startsCustom, let hours {
      let (amount, unit) = SLADurationUnit.decompose(hours: hours)
      _slaCustomAmount = State(initialValue: amount)
      _slaCustomUnit = State(initialValue: unit)
    }
  }

  var body: some View {
    if isActive {
      activeBody
    } else {
      Color.clear
    }
  }

  private var activeBody: some View {
    Form {
      sourceScopeSection
      behaviorSection
      backportSection
      slaSection
      refreshSection
    }
    .settingsDetailFormStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsReviewsPane("general"))
  }

  private var sourceScopeSection: some View {
    Section {
      monitoredRepositoriesSummary
      TextField("Excluded Repositories", text: $draft.excludeRepositoriesText)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsReviewsExcludedReposField
        )
      Toggle("Expand organizations to repositories", isOn: $draft.expandOrganizations)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsDepsExpandOrganizationsToggle
        )
    } header: {
      Text("Sources")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        """
        Configure shared monitored repositories in Settings > Repositories. \
        Excluded repositories remain Reviews-specific. When organization expansion is \
        on, each org resolves to its repositories so per-repo syncs can stagger across the \
        schedule.
        """
      )
    }
  }

  private var monitoredRepositoriesSummary: some View {
    let repositories = draft.normalizedRepositories
    let legacyOrganizations = draft.normalizedOrganizations
    let repositoriesLabel =
      repositories.isEmpty
      ? "No repositories enabled"
      : "\(repositories.count) repositories enabled"
    let organizationsLabel =
      legacyOrganizations.isEmpty
      ? nil
      : "\(legacyOrganizations.count) legacy organization sources still active"

    return VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Monitored Repositories")
        .font(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(repositoriesLabel)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if let organizationsLabel {
        Text(organizationsLabel)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Button("Open Repositories") {
        navigationRequest = SettingsNavigationRequest(target: .section(.repositories))
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .fixedSize(horizontal: true, vertical: true)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsReviewsRepositoriesButton
      )
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsReviewsRepositoriesSummary)
  }

  private var behaviorSection: some View {
    Section {
      Picker("Merge Method", selection: $draft.mergeMethodRaw) {
        ForEach(TaskBoardGitHubMergeMethod.allCases) { method in
          Text(method.title).tag(method.rawValue)
        }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsReviewsMergeMethodField)
      Toggle("Show label descriptions in pickers", isOn: $draft.showLabelDescriptions)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsDepsShowLabelDescriptionsToggle
        )
      Picker("Frequently used labels", selection: $draft.frequentLabelsCount) {
        ForEach(Self.frequentLabelsCountRange, id: \.self) { count in
          Text(verbatim: "\(count)").tag(count)
        }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsDepsFrequentLabelsCountField
      )
    } header: {
      Text("Actions")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        """
        Merge method drives Merge and Auto actions. Toggle label descriptions to append the \
        repository-defined description next to each label name in the Add Label menus. The \
        Add Label dropdown surfaces the top N most-used labels per repository at the top.
        """
      )
    }
  }

  private var slaSection: some View {
    Section {
      Toggle(
        "Highlight PRs exceeding SLA",
        isOn: Binding(
          get: { draft.slaThresholdHours != nil },
          set: { enabled in
            if enabled {
              slaIsCustom = false
              draft.slaThresholdHours = 48
            } else {
              draft.slaThresholdHours = nil
            }
          }
        )
      )
      .accessibilityIdentifier("settings.reviews.display.slaToggle")
      if draft.slaThresholdHours != nil {
        Picker("SLA Threshold", selection: slaSelectionBinding) {
          ForEach(Self.slaPresets, id: \.hours) { preset in
            Text(preset.label).tag(SLAThresholdSelection.preset(preset.hours))
          }
          Divider()
          Text("Custom…").tag(SLAThresholdSelection.custom)
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("settings.reviews.display.slaPicker")
      }
      if draft.slaThresholdHours != nil, slaIsCustom {
        LabeledContent("Threshold") {
          HStack(spacing: 0) {
            TextField("", value: $slaCustomAmount, format: .number)
              .textFieldStyle(.roundedBorder)
              .controlSize(.small)
              .scaledFont(.subheadline)
              .multilineTextAlignment(.trailing)
              .frame(width: 64)
            Stepper(value: $slaCustomAmount, in: slaCustomStepperRange) {}
              .labelsHidden()
              .controlSize(.small)
              .padding(.leading, 4)
            Picker("Unit", selection: $slaCustomUnit) {
              ForEach(SLADurationUnit.allCases) { unit in
                Text(unit.label).tag(unit)
              }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .padding(.leading, HarnessMonitorTheme.spacingSM)
          }
        }
        .accessibilityIdentifier("settings.reviews.display.slaStepper")
        .onChange(of: slaCustomAmount) { _, _ in commitSlaCustom() }
        .onChange(of: slaCustomUnit) { oldUnit, _ in handleSlaUnitChange(from: oldUnit) }
      }
    } header: {
      Text("SLA")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        "When enabled, PRs open longer than the threshold are flagged with a badge in the review list."
      )
    }
    .onChange(of: draft.slaThresholdHours) { _, newValue in
      guard let hours = newValue else { return }
      if Self.slaPresets.contains(where: { $0.hours == hours }) {
        slaIsCustom = false
      }
    }
  }

  private var slaSelectionBinding: Binding<SLAThresholdSelection> {
    Binding(
      get: {
        guard let hours = draft.slaThresholdHours else { return .custom }
        if slaIsCustom { return .custom }
        return Self.slaPresets.contains(where: { $0.hours == hours })
          ? .preset(hours)
          : .custom
      },
      set: { selection in
        switch selection {
        case .preset(let hours):
          slaIsCustom = false
          draft.slaThresholdHours = hours
        case .custom:
          if !slaIsCustom {
            let (amount, unit) = SLADurationUnit.decompose(hours: draft.slaThresholdHours ?? 48)
            slaCustomAmount = amount
            slaCustomUnit = unit
          }
          slaIsCustom = true
        }
      }
    )
  }

  private var slaCustomStepperRange: ClosedRange<Int> {
    let upper =
      switch slaCustomUnit {
      case .hours: 8_760
      case .days: 365
      case .weeks: 52
      }
    return 1...upper
  }

  private func commitSlaCustom() {
    guard slaIsCustom else { return }
    let hours = max(1, slaCustomAmount * slaCustomUnit.hoursPerUnit)
    if draft.slaThresholdHours != hours {
      draft.slaThresholdHours = hours
    }
  }

  private func handleSlaUnitChange(from oldUnit: SLADurationUnit) {
    guard slaIsCustom else { return }
    let totalHours = slaCustomAmount * oldUnit.hoursPerUnit
    let converted = max(1, totalHours / slaCustomUnit.hoursPerUnit)
    let range = slaCustomStepperRange
    slaCustomAmount = min(max(converted, range.lowerBound), range.upperBound)
    commitSlaCustom()
  }

  private var refreshSection: some View {
    Section {
      SettingsDurationPickerRow(
        title: "Refresh Each Repository Every",
        presets: Self.refreshPresetsSeconds,
        minSeconds: Self.minimumDurationSeconds,
        seconds: $draft.perRepositoryIntervalSeconds,
        pickerAccessibilityIdentifier:
          HarnessMonitorAccessibility.settingsReviewsPerRepoIntervalField
      )
      Picker("Max Concurrent Fetches", selection: $draft.maxConcurrentRepositoryFetches) {
        ForEach(Self.maxConcurrentRange, id: \.self) { count in
          Text(verbatim: "\(count)").tag(count)
        }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsReviewsMaxConcurrentField
      )
      SettingsDurationPickerRow(
        title: "Cache Max Age",
        presets: Self.cachePresetsSeconds,
        minSeconds: Self.minimumDurationSeconds,
        seconds: $draft.cacheMaxAgeSeconds,
        pickerAccessibilityIdentifier:
          HarnessMonitorAccessibility.settingsReviewsCacheMaxAgeField
      )
    } header: {
      Text("Sync Schedule")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        """
        Each repository is fetched on its own timer. With 12 repositories and a 5-minute \
        interval, expect a sync roughly every 25 seconds.
        """
      )
    }
  }

  private static let slaPresets: [(hours: Int, label: String)] = [
    (24, "1 day"),
    (48, "2 days"),
    (168, "1 week"),
    (336, "2 weeks"),
    (720, "1 month"),
  ]

  private static let minimumDurationSeconds: UInt64 = 30
  private static let refreshPresetsSeconds: [UInt64] =
    [30, 60, 120, 300, 600, 900, 1_800, 3_600]
  private static let cachePresetsSeconds: [UInt64] =
    [60, 300, 600, 900, 1_800, 3_600, 7_200, 21_600]
  private static let maxConcurrentRange = ClosedRange(
    uncheckedBounds: (
      lower: DashboardReviewsPreferences.minimumConcurrentRepositoryFetches,
      upper: DashboardReviewsPreferences.maximumConcurrentRepositoryFetches
    )
  )
  private static let frequentLabelsCountRange = ClosedRange(
    uncheckedBounds: (
      lower: DashboardReviewsPreferences.minimumFrequentLabelsCount,
      upper: DashboardReviewsPreferences.maximumFrequentLabelsCount
    )
  )
}

private enum SLAThresholdSelection: Hashable {
  case preset(Int)
  case custom
}

private enum SLADurationUnit: String, CaseIterable, Identifiable {
  case hours
  case days
  case weeks

  var id: String { rawValue }

  var label: String {
    switch self {
    case .hours: "Hours"
    case .days: "Days"
    case .weeks: "Weeks"
    }
  }

  var hoursPerUnit: Int {
    switch self {
    case .hours: 1
    case .days: 24
    case .weeks: 168
    }
  }

  static func decompose(hours: Int) -> (amount: Int, unit: Self) {
    if hours >= 168, hours.isMultiple(of: 168) { return (hours / 168, .weeks) }
    if hours >= 24, hours.isMultiple(of: 24) { return (hours / 24, .days) }
    return (max(hours, 1), .hours)
  }
}
