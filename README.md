# WiimotePair

A utility app that pairs Wii Remotes to Macs running macOS 13.0 or newer.

macOS can't pair a Wii Remote through System Settings, because the remote expects a PIN that the Bluetooth settings can't enter. WiimotePair pairs it properly, so the remote stays bonded to your Mac and reconnects whenever you press a button on it, just like it does with a Wii.

The latest download can be found [here](https://github.com/dolphin-emu/WiimotePair/releases/latest).

## Features

- **Pairing:** finds a remote in sync mode and pairs it, retrying automatically if pairing fails.
- **Connection management:** connect, disconnect, and see the live connection state of every paired remote.
- **Auto-connect:** optionally connects to paired remotes when the app opens.
- **Live status:** battery level, extension (e.g. Nunchuk) detection, and the current player LED.
- **Player LEDs:** a newly connected remote is assigned the lowest free player (P1–P4) and can be changed at any time.
- **Rumble test:** briefly rumbles a remote to identify it.
- **Forget:** unpairs a remote from macOS so you can start over.

Supported remotes are the original Wii Remote (RVL-CNT-01) and the Wii Remote Plus (RVL-CNT-01-TR).

## Usage

1. Open WiimotePair and click **Pair New Remote** (⌘N).
2. Open the battery cover on the remote and press the red **SYNC** button.
3. Keep the remote close to your Mac until pairing finishes. WiimotePair then connects to it and lights up its player LED.

After pairing, pressing any button on the remote reconnects it to your Mac, even when WiimotePair isn't running. In [Dolphin](https://dolphin-emu.org), set the controller to **Real Wii Remote** under Controllers.

## Troubleshooting

- **The remote isn't found:** press SYNC again; sync mode only lasts about 20 seconds. Make sure the remote isn't connected to a nearby Wii.
- **The remote paired but didn't connect:** press any button on it.
- **"Status unavailable":** macOS connected the remote without starting its HID profile. WiimotePair retries this automatically; if it still shows, disconnect and reconnect the remote.
- **Anything else:** use **Forget This Remote…** from the remote's "…" menu and pair it again.

## How it works

- **Pairing** uses the Wii's "SYNC button" PIN scheme, where the PIN is the host's Bluetooth address in reverse byte order. This requires private IOBluetooth APIs (see the `*+Private.h` headers).
- **Status, LEDs, and rumble:** once connected, macOS's own Bluetooth HID profile owns the remote's L2CAP control and interrupt channels and publishes it as a HID device. WiimotePair talks to the remote through that device with IOHIDManager instead of opening its own L2CAP channels, which would conflict with the system.
- **Permissions:** under the App Sandbox, opening the HID device requires the `com.apple.security.device.usb` entitlement, even though the remote is connected over Bluetooth. Input Monitoring permission isn't needed, because the remote is a game controller, not a keyboard.
- **Forget** uses the private `-[IOBluetoothDevice remove]`. macOS completes the unpairing a few seconds after the call returns, so WiimotePair waits for it to finish before updating the list.

## Building

Open `WiimotePair.xcodeproj` in Xcode 15 or newer and run the **WiimotePair** scheme. To sign with your own team, set it in the target's **Signing & Capabilities** settings, or override it on the command line:

```sh
xcodebuild -project WiimotePair.xcodeproj -scheme WiimotePair -configuration Release \
  DEVELOPMENT_TEAM=<your team ID> -allowProvisioningUpdates build
```

Sign with a stable identity rather than ad hoc, so that macOS keeps the Bluetooth permission between builds.

Diagnostic logs are written to the unified log under the `org.dolphin-emu.WiimotePair` subsystem:

```sh
/usr/bin/log stream --info --style compact --predicate 'subsystem == "org.dolphin-emu.WiimotePair"'
```

## License

WiimotePair is licensed under the GNU General Public License, version 2 or later. See [LICENSES/GPL-2.0-or-later.txt](LICENSES/GPL-2.0-or-later.txt).

Based on the work of TellowKrinkle, jpapetti0713, OatmealDome, and JamsheedMistri.

"Wii" is a trademark of Nintendo. Dolphin is not affiliated with Nintendo in any way.
