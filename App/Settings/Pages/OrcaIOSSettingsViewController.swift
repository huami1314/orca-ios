import UIKit

/// Settings › Orca iOS: what only this app does, beyond the official one. Sending while an agent works,
/// picture in picture, and Live Activities. All kept on this phone.
final class OrcaIOSSettingsViewController: SettingsPageViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "orcaios.settings.title", defaultValue: "Orca iOS")
    rebuild()
  }

  private func rebuild() {
    let send = SendWhileWorking.current
    sections = [
      Section(
        header: String(localized: "orcaios.chat.sendHeading", defaultValue: "SENDING"),
        footer: String(
          localized: "orcaios.chat.sendFooter",
          defaultValue: "While the agent works, tapping send does this; holding send offers the other."),
        rows: [
          .menu(
            title: String(localized: "orcaios.chat.sendWhileWorking", defaultValue: "Send while working"),
            value: send.title,
            options: SendWhileWorking.allCases.map { choice in
              Option(title: choice.title, subtitle: choice.subtitle, selected: choice == send) { [weak self] in
                SendWhileWorking.current = choice
                self?.rebuild()
              }
            })
        ]),
      Section(
        header: nil,
        footer: nil,
        rows: [
          .button(title: String(localized: "orcaios.settings.showTips", defaultValue: "Show tips again")) { [weak self] in
            SendHoldTip.seen = false
            self?.rebuild()
          }
        ]),
      Section(
        header: String(localized: "orcaios.settings.tabsHeading", defaultValue: "TABS"),
        footer: String(
          localized: "orcaios.settings.tabsFooter", defaultValue: "Hide the tabs you don't use. Feed always shows."),
        rows: HomeTab.allCases.filter(\.canHide).map { tab in
          .toggle(title: tab.title, isOn: !HomeTab.hidden.contains(tab)) { on in
            var hidden = HomeTab.hidden
            if on { hidden.remove(tab) } else { hidden.insert(tab) }
            HomeTab.hidden = hidden
          }
        }),
      Section(
        header: String(localized: "orcaios.settings.pipHeading", defaultValue: "PICTURE IN PICTURE"),
        footer: String(
          localized: "orcaios.settings.pipFooter",
          defaultValue: "Never lose track of your agents while scrolling TikTok."),
        rows: [
          .toggle(
            title: String(localized: "orcaios.pip.onLeave", defaultValue: "Picture in Picture on leaving"),
            isOn: PiPCenter.startsOnLeave
          ) { on in PiPCenter.startsOnLeave = on },
          .toggle(
            title: String(localized: "orcaios.pip.compact", defaultValue: "Mini status bar"),
            isOn: PiPCenter.usesCompactLayout
          ) { [weak self] on in
            PiPCenter.usesCompactLayout = on
            self?.rebuild()
          },
        ] + (PiPCenter.usesCompactLayout ? [] : [
          .toggle(
            title: String(localized: "orcaios.pip.commands", defaultValue: "Show each command in Picture in Picture"),
            isOn: PiPCenter.showsCommands
          ) { on in PiPCenter.showsCommands = on },
        ])),
      Section(
        header: String(localized: "orcaios.settings.activityHeading", defaultValue: "LIVE ACTIVITIES"),
        footer: String(
          localized: "orcaios.settings.activityFooter",
          defaultValue: "A working agent shows on the Lock Screen and in the Dynamic Island until it stops."),
        rows: [
          .toggle(
            title: String(localized: "orcaios.settings.activityToggle", defaultValue: "Show working agents"),
            isOn: AgentActivityCenter.enabled
          ) { on in AgentActivityCenter.enabled = on }
        ]),
    ]
  }
}
