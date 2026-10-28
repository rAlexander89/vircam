# Icons

- `AppIcon.png`: the app icon, 1024×1024.
- `TrayIcon.png`: the menu bar icon source: black letters and a red dot on a transparent
  background. The menu bar shows it in one color so macOS can match light and dark menu
  bars. The dot is shown while Vircam is on and hidden while it's off.

To change an icon, replace the PNG, run `make icons` to regenerate
`mac/App/Assets.xcassets`, and commit both.
