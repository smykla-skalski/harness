import HarnessMonitorKit
import SwiftUI

struct PreferencesNotificationsSection: View {
  @Bindable var notifications: HarnessMonitorUserNotificationController
  @State private var selectedPreset: HarnessMonitorNotificationPreset = .basic

  var body: some View {
    Form {
      statusSection
      authorizationSection
      presetSection
      contentSection
      nativeOptionsSection
      attachmentSection
      deliverySection
      responseSection
    }
    .preferencesDetailFormStyle()
    .task { await notifications.refreshStatus() }
  }

  private var statusSection: some View {
    Section {
      LabeledContent("Authorization", value: notifications.settingsSnapshot.authorizationStatus)
      LabeledContent("Alerts", value: notifications.settingsSnapshot.alertSetting)
      LabeledContent("Sound", value: notifications.settingsSnapshot.soundSetting)
      LabeledContent("Badges", value: notifications.settingsSnapshot.badgeSetting)
      LabeledContent(
        "Notification Center",
        value: notifications.settingsSnapshot.notificationCenterSetting
      )
      LabeledContent("Lock Screen", value: notifications.settingsSnapshot.lockScreenSetting)
      LabeledContent("Alert Style", value: notifications.settingsSnapshot.alertStyle)
      LabeledContent("Previews", value: notifications.settingsSnapshot.showPreviews)
      LabeledContent("Time Sensitive", value: notifications.settingsSnapshot.timeSensitiveSetting)
      LabeledContent("Categories", value: "\(notifications.registeredCategoryCount)")
      LabeledContent("Pending", value: "\(notifications.pendingRequestCount)")
      LabeledContent("Delivered", value: "\(notifications.deliveredNotificationCount)")
      LabeledContent("Last Result", value: notifications.lastResult)
        .textSelection(.enabled)
    } header: {
      Text("System Status")
    } footer: {
      Text("These values come from the system notification center for this app.")
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesNotificationsStatus)
  }

  private var authorizationSection: some View {
    Section("Authorization") {
      HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
        HarnessMonitorWrapLayout(
          spacing: HarnessMonitorTheme.itemSpacing,
          lineSpacing: HarnessMonitorTheme.itemSpacing
        ) {
          ForEach(HarnessMonitorNotificationAuthorizationProfile.allCases) { profile in
            HarnessMonitorAsyncActionButton(
              title: profile.title,
              tint: nil,
              variant: profile == .standard ? .prominent : .bordered,
              isLoading: notifications.isWorking,
              accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
                "Request \(profile.rawValue) notifications"
              ),
              action: { await notifications.requestAuthorization(profile: profile) }
            )
          }
          HarnessMonitorAsyncActionButton(
            title: "Refresh Settings",
            tint: .secondary,
            variant: .bordered,
            isLoading: notifications.isWorking,
            accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
              "Refresh Notification Settings"
            ),
            action: { await notifications.refreshStatus() }
          )
        }
      }
    }
  }

  private var presetSection: some View {
    Section("Presets") {
      Picker("Preset", selection: $selectedPreset) {
        ForEach(HarnessMonitorNotificationPreset.allCases) { preset in
          Text(preset.title).tag(preset)
        }
      }
      .harnessNativeFormControl()
      .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesNotificationsPresetPicker)

      HarnessMonitorActionButton(
        title: "Load Preset",
        tint: .secondary,
        variant: .bordered,
        accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
          "Load Notification Preset"
        )
      ) {
        notifications.applyPreset(selectedPreset)
      }
    }
  }

  private var contentSection: some View {
    Section {
      TextField("Title", text: $notifications.draft.title)
        .textFieldStyle(.roundedBorder)
      TextField("Subtitle", text: $notifications.draft.subtitle)
        .textFieldStyle(.roundedBorder)
      TextField("Body", text: $notifications.draft.body, axis: .vertical)
        .lineLimit(2...4)
        .textFieldStyle(.roundedBorder)
      TextField("Thread", text: $notifications.draft.threadIdentifier)
        .textFieldStyle(.roundedBorder)
      TextField("Target Content", text: $notifications.draft.targetContentIdentifier)
        .textFieldStyle(.roundedBorder)
      TextField("Filter Criteria", text: $notifications.draft.filterCriteria)
        .textFieldStyle(.roundedBorder)
      TextField("Summary Argument", text: $notifications.draft.summaryArgument)
        .textFieldStyle(.roundedBorder)
      Stepper(
        "Summary count: \(notifications.draft.summaryArgumentCount)",
        value: $notifications.draft.summaryArgumentCount,
        in: 1...12
      )
      Toggle("Include userInfo", isOn: $notifications.draft.includesUserInfo)
      Toggle("Set badge", isOn: $notifications.draft.includesBadge)
      if notifications.draft.includesBadge {
        Stepper(
          "Badge number: \(notifications.draft.badgeNumber)",
          value: $notifications.draft.badgeNumber,
          in: 0...99
        )
      }
    } header: {
      Text("Content")
    }
  }

  private var nativeOptionsSection: some View {
    Section {
      Picker("Actions", selection: $notifications.draft.category) {
        ForEach(HarnessMonitorNotificationCategoryKind.allCases) { category in
          Text(category.title).tag(category)
        }
      }
      .harnessNativeFormControl()
      .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesNotificationsCategoryPicker)

      Picker("Sound", selection: $notifications.draft.soundMode) {
        ForEach(HarnessMonitorNotificationSoundMode.allCases) { soundMode in
          Text(soundMode.title).tag(soundMode)
        }
      }
      .harnessNativeFormControl()
      .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesNotificationsSoundPicker)

      Picker("Interruption", selection: $notifications.draft.interruptionMode) {
        ForEach(HarnessMonitorNotificationInterruptionMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .harnessNativeFormControl()

      LabeledContent("Relevance") {
        Slider(value: $notifications.draft.relevanceScore, in: 0...1)
          .frame(maxWidth: 220)
      }
    } header: {
      Text("Native Options")
    } footer: {
      Text("Time-sensitive delivery remains available when the system allows it.")
    }
  }

  private var attachmentSection: some View {
    Section {
      Picker("Attachment", selection: $notifications.draft.attachmentMode) {
        ForEach(HarnessMonitorNotificationAttachmentMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .harnessNativeFormControl()
      .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesNotificationsAttachmentPicker)

      if notifications.draft.attachmentMode == .sampleImage {
        Toggle("Hide thumbnail", isOn: $notifications.draft.hidesAttachmentThumbnail)
        Picker("Thumbnail clip", selection: $notifications.draft.thumbnailClipping) {
          ForEach(HarnessMonitorNotificationThumbnailClipping.allCases) { clipping in
            Text(clipping.title).tag(clipping)
          }
        }
        .harnessNativeFormControl()
        Stepper(
          "Thumbnail time: \(notifications.draft.thumbnailTime, specifier: "%.1f")s",
          value: $notifications.draft.thumbnailTime,
          in: 0...5,
          step: 0.5
        )
      }
    } header: {
      Text("Attachments")
    }
  }

  private var deliverySection: some View {
    Section {
      Picker("Trigger", selection: $notifications.draft.triggerMode) {
        ForEach(HarnessMonitorNotificationTriggerMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .harnessNativeFormControl()
      .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesNotificationsTriggerPicker)

      switch notifications.draft.triggerMode {
      case .immediate:
        EmptyView()
      case .timeInterval:
        Stepper(
          "Delay: \(Int(notifications.draft.delaySeconds))s",
          value: $notifications.draft.delaySeconds,
          in: 1...120,
          step: 1
        )
      case .calendar:
        DatePicker(
          "Delivery time",
          selection: $notifications.draft.calendarDate,
          displayedComponents: [.date, .hourAndMinute]
        )
      }

      HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
        HarnessMonitorWrapLayout(
          spacing: HarnessMonitorTheme.itemSpacing,
          lineSpacing: HarnessMonitorTheme.itemSpacing
        ) {
          HarnessMonitorAsyncActionButton(
            title: "Send Test Notification",
            tint: nil,
            variant: .prominent,
            isLoading: notifications.isWorking,
            accessibilityIdentifier: HarnessMonitorAccessibility.preferencesNotificationsSendButton,
            action: { await notifications.deliverDraft() }
          )
          HarnessMonitorAsyncActionButton(
            title: "Clear Pending",
            tint: .secondary,
            variant: .bordered,
            isLoading: notifications.isWorking,
            accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
              "Clear Pending Notifications"
            ),
            action: { await notifications.removeAllPendingRequests() }
          )
          HarnessMonitorAsyncActionButton(
            title: "Clear Delivered",
            tint: .secondary,
            variant: .bordered,
            isLoading: notifications.isWorking,
            accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
              "Clear Delivered Notifications"
            ),
            action: { await notifications.removeAllDeliveredNotifications() }
          )
          HarnessMonitorAsyncActionButton(
            title: "Reset Badge",
            tint: .secondary,
            variant: .bordered,
            isLoading: notifications.isWorking,
            accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
              "Reset Notification Badge"
            ),
            action: { await notifications.resetBadge() }
          )
        }
      }
    } header: {
      Text("Delivery")
    }
  }

  @ViewBuilder private var responseSection: some View {
    if let lastResponse = notifications.lastResponse {
      Section("Last Response") {
        LabeledContent("Action", value: lastResponse.actionIdentifier)
        LabeledContent("Request", value: lastResponse.requestIdentifier)
        LabeledContent("Category", value: lastResponse.categoryIdentifier)
        if let textInput = lastResponse.textInput {
          LabeledContent("Text", value: textInput)
        }
        LabeledContent(
          "Received",
          value: lastResponse.receivedAt.formatted(date: .abbreviated, time: .standard)
        )
      }
    }
  }
}

#Preview("Preferences Notifications Section") {
  PreferencesNotificationsSection(
    notifications: HarnessMonitorUserNotificationController.preview()
  )
  .frame(width: 720)
}
