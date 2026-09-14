# Clix

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 13+](https://img.shields.io/badge/Platform-macOS%2013%2B-lightgrey.svg)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-support-ff5e5b.svg)](https://ko-fi.com/anggarasaja)

A small menu bar app for macOS that remaps the extra buttons on your mouse to
keyboard shortcuts, applications, or built-in system functions — the way Logi
Options+ does, without the rest of Logi Options+.

## What it does

Pick a mouse button in the sidebar, switch on "Remap this button", and choose
one of:

| Action | Notes |
| --- | --- |
| **Keyboard Shortcut** | Records any combination, including ones macOS reserves for itself — ⌃←, ⌃↑, ⌘Space, ⌘Tab, ⌘Q, function keys |
| **Launch App** | Opens (or activates) any app you pick |
| **System Function** | ~40 built-ins: Mission Control, spaces, volume, media, brightness, screenshots, copy/paste, tabs, window management, lock screen, sleep display, double-click |
| **Trackpad Gesture** | Makes the button do what a trackpad gesture does — a back button that acts as a four-finger swipe left |
| **Open URL** | A web address or a custom scheme such as `raycast://` |
| **Run Command** | A shell command, run detached with `zsh -lc` |
| **Do Nothing** | Swallows the click — for a button your mouse fires by accident |

This works in both directions. A gesture can *trigger* an action, the way a
mouse button does — three, four and five finger taps, and three and four
finger swipes in each direction. And a gesture can *be* the action, so a mouse
button stands in for one.

Each button also chooses **when it fires**: *On Click*, as the button goes
down, which is how a click normally feels and is the default; or *On Release*,
when you let go, so holding the button does nothing until then. That is the
one to pick for a button you catch by accident, or for anything you would
rather not set off mid-drag. Either way the click itself is swallowed, so an
application never sees half of one. Gestures are recognised once, when the
fingers lift, so the choice does not apply to them.

Left and right click are deliberately not remappable, so a bad binding can
never leave the machine unusable.

Unbound buttons pass straight through, untouched.

### Logitech mice that hold their side buttons

Some Logitech mice have no tilt wheel and offer horizontal scrolling by holding
a side button and turning the wheel — the Signature M650 and the Lift among
them. To tell a click apart from the start of such a scroll, the firmware
*withholds* the press: nothing is sent while you hold the button, and when you
finally let go the press and the release arrive together, a few milliseconds
apart. *On Click* cannot work, because at press time there is no event for any
tap to see. Measured on an M650 L, a two-second hold of Back reaches macOS as a
9 ms click.

The usual advice is to turn horizontal scrolling off in Logi Options+. Clix can
do it without that. When a mouse like this is connected, Settings offers
**Instant side buttons**, which uses HID++ — the protocol Logitech devices speak
over a vendor HID collection, reachable over either a Bolt/Unifying receiver or
Bluetooth — to *divert* the two navigation controls. A diverted button is no
longer reported as a click; the device hands it to the host the moment it goes
down, because the firmware is no longer waiting to find out whether a scroll is
coming. The same two-second hold then measures a genuine two seconds, and
hold-to-scroll-sideways on those buttons is switched off for as long as Clix
holds them.

Nothing is written permanently to the mouse. The diversion lasts only while
Clix is running, is handed back when the app quits or the switch is turned off,
and is reapplied by itself when the mouse wakes or the receiver is replugged. A
diverted button you have not bound is posted back as an ordinary click, so it
still navigates — just without the wait.

**Bluetooth needs Input Monitoring.** Which permission this feature wants
depends on how the mouse is connected, because the two routes reach HID++
through different HID nodes:

| Connection | HID++ lives on | Permission |
| --- | --- | --- |
| Logi Bolt / Unifying receiver | the receiver's vendor-only interface | none beyond Accessibility |
| Bluetooth | the mouse node itself, which is a pointing device | **Input Monitoring** |

macOS refuses `IOHIDDeviceOpen` on a pointing device without Input Monitoring,
which is a *separate* permission from the Accessibility access the event tap
needs — having one does not imply the other. When it is missing, Clix says so
in Settings and offers a button to the right pane. Switch Clix on in Privacy &
Security → Input Monitoring and then **quit and reopen Clix**: macOS does not
apply this permission to a running app.

If a connection attempt fails — the mouse asleep, Bluetooth still settling
after switching from the receiver — Clix retries with a backoff of up to ten
seconds rather than giving up, so the setting reappears on its own once the
mouse answers.

Clicks are intercepted at the HID tap, ahead of the window server. That
placement matters for *On Click*: a button swallowed further downstream has
still been seen by the window server, which treats it as a drag in progress
and holds the action back until the button comes up — a space switch bound to
*On Click* would not happen until you let go. If the HID placement is ever
refused, Clix falls back to the session tap and says so in the footer.

## Build and install

```sh
./build.sh --install     # builds build/Clix.app and copies it to /Applications
./build.sh               # build only
```

Then launch Clix and grant **Accessibility** access when prompted
(System Settings → Privacy & Security → Accessibility). Clix needs it both to
see mouse buttons and to send keystrokes; nothing works without it.

Clix lives in the menu bar only — no Dock icon. Click the mouse icon for
Settings, the on/off switch, or Quit.

Requires macOS 13 or later. Swift 5.10 command line tools are enough to build
it; Xcode is not needed.

## Is it working?

The footer of the Settings window shows a status dot:

- **Green** — Clix is intercepting input. The line underneath names the last
  thing it saw, e.g. `Middle Click → Mission Control`.
- **Orange** — Clix is not listening, which on macOS means Accessibility access
  is missing.

Each binding also has a **Test Action** button that runs it directly, so a
broken action can be told apart from an input that never arrived.

Without Accessibility access, `CGEvent.post` silently does nothing — macOS
raises no error, keystrokes simply never appear. That is why Clix replaces its
whole interface with a permission screen until access is granted.

## Standing in for a gesture

Pick **Trackpad Gesture** as a button's action to have it do what that gesture
does: bind the back button to Four-Finger Swipe Left and it moves one space to
the right, exactly as the swipe would.

macOS has no public way to inject finger contacts, so Clix reproduces the
gesture's *effect* rather than the contacts themselves — which is the part a
side button is wanted for anyway. For the space and App Exposé gestures that
means sending the shortcut macOS assigns them, so those shortcuts have to stay
enabled in Keyboard Settings; Mission Control needs nothing.

| Gesture | What the button does |
| --- | --- |
| Three or Four-Finger Swipe Left | Move Right a Space |
| Three or Four-Finger Swipe Right | Move Left a Space |
| Three or Four-Finger Swipe Up | Mission Control |
| Three or Four-Finger Swipe Down | Application Windows |
| Three-Finger Tap | Look Up |

Swiping is content-relative, which is why swiping *left* moves *right*. Four
and five finger taps do nothing by default, so there is nothing to stand in
for and they are not offered.

## Reading gestures from the trackpad

Gestures are read straight from the trackpad through the private
MultitouchSupport framework, since macOS has no public API for system-wide
finger contacts. Clix loads it at runtime and degrades to mouse-only if it is
ever unavailable.

**Gestures are observed, not intercepted.** Clix cannot take a gesture away
from macOS, so a three-finger swipe bound in Clix will *also* switch spaces if
that is still enabled in Trackpad settings. Turn the system gesture off there
for exclusive use. The editor flags each gesture that has a known conflict.

Recognition: a gesture starts when three or more fingers land and is classified
once when they lift, so a swipe never also registers as a tap. A contact under
0.35s that moves less than 4% of the trackpad is a tap; movement past 10% along
the dominant axis is a swipe. Distance is measured only while every finger is
down, and the finger count is the one held for the most frames, so a hand that
lands raggedly or a thumb that brushes the pad does not change which gesture
you get.

If the status line says trackpad contact has never been seen, macOS may be
withholding raw input — grant Clix **Input Monitoring** as well.

## Managing the button list

The sidebar starts with a common set (middle click through Button 8) and is yours from there:

- **+** adds a mouse button or a trackpad gesture. Pick it from the list by
  name, or just perform it and the sheet identifies it.
- **−**, the Delete key, or right-click → Remove deletes an entry, after
  confirming.

Pressing a listed button jumps to its row, so you don't have to guess whether a
side button reports as Button 4 or Button 7. While the add sheet is open,
presses are held back rather than run, so identifying a button won't also fire
whatever it's bound to.

The list lives in the same JSON file as the bindings, so it survives restarts.

## Where settings live

`~/Library/Application Support/Clix/bindings.json` — plain JSON, safe to edit
or copy between machines while Clix is quit.

## Re-granting Accessibility after a rebuild

`build.sh` ad-hoc signs the app, and an ad-hoc signature changes with every
build, so macOS treats each rebuild as a new app and drops the Accessibility
grant. To keep it:

1. Create a self-signed code signing certificate in Keychain Access
   (Certificate Assistant → Create a Certificate → *Code Signing*, self-signed).
2. Build with it: `CODESIGN_IDENTITY="My Cert Name" ./build.sh --install`

Otherwise, remove the old Clix entry in Privacy & Security → Accessibility and
add the new one after each rebuild.

## Notes on a few actions

- **Mission Control**, **Application Windows** and the space-switching actions
  send the default macOS shortcut, so they follow whatever you've set in
  Keyboard Settings.
- **Show Desktop** sends F11; if you've turned that shortcut off, it won't do
  anything.
- **Launchpad** was removed in macOS 26. On those systems the action falls back
  to Spotlight.
- Keystrokes are posted the way hardware sends them: each modifier goes down
  and up as its own `flagsChanged` event, and the flags keep the
  device-dependent bit naming the side of the keyboard the modifier came from
  along with the fn and numeric-pad bits an Apple keyboard sets on the arrow
  and function keys. macOS's own hotkeys — ⌃←, ⌃↑, ⌘Space, F11 — match against
  all of that and silently ignore an event that is missing any of it.
- The shortcut recorder installs a temporary keyboard tap while the field is
  focused, because `NSEvent` never sees system hotkeys like ⌃←. The tap stops
  on the first key, when the field loses focus, and after 8 seconds regardless.
- Shortcuts are stored as **key codes**, not characters, so a binding keeps
  hitting the same physical key if you switch keyboard layouts. On a non-US
  layout the label shown may not match the legend on the key.

## Layout

```
Sources/Clix/
  main.swift            NSApplication bootstrap (accessory app, no Dock icon)
  AppDelegate.swift     Menu bar item, settings window, wiring
  MouseEventTap.swift   CGEvent tap over the non-primary mouse buttons
  ActionRunner.swift    Posts keystrokes, media keys, launches apps, runs commands
  Model.swift           Buttons, key combos, app targets, actions, triggers
  SystemAction.swift    The built-in function catalogue
  BindingStore.swift    Persistence
  SettingsView.swift    The UI
  ShortcutRecorder.swift  Click-to-record shortcut field
  KeyCaptureTap.swift   Temporary keyboard tap that catches reserved hotkeys
  HIDPP.swift           HID++ 2.0 over a Logitech receiver or Bluetooth
  LogitechSideButtons.swift  Diverts side buttons that the firmware holds back
  TrackpadMonitor.swift MultitouchSupport bridge and gesture recognition
  TrackpadGesture.swift The gesture catalogue
  Accessibility.swift   Permission state
  MainMenu.swift        Hidden menu that keeps ⌘C/⌘V alive in text fields
  KeyNames.swift        Key code → label
  LoginItem.swift       Launch at login
```

## Support

Clix is free and always will be. If it saved you from installing Logi
Options+, you can [buy me a coffee](https://ko-fi.com/anggarasaja).
[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/anggarasaja)

## Contributing

Issues and pull requests are welcome. The one thing worth knowing before you
open a PR: most of this code talks to undocumented corners of macOS — event
tap placement, synthesized modifier flags, the MultitouchSupport bridge — and
the comments explain *why* a thing is done the awkward way. Please keep that
reasoning attached to the code if you change it, or the next person will
tidy the workaround away and quietly break it.

## License

MIT — see [LICENSE](LICENSE).
