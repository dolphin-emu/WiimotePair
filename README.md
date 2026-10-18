# WiimotePair

A utility app that pairs Wii Remotes to Macs running macOS 12.0 or newer.

The latest download can be found [here](https://github.com/dolphin-emu/WiimotePair/releases/latest).

## Pairing and using the remote in Dolphin

1. Quit Dolphin and other Wii Remote utilities while pairing for the first time.
2. Open WiimotePair and allow Bluetooth access if macOS asks for it.
3. Press the red **SYNC** button inside the battery compartment. Do not use 1+2
   for this first-time pairing procedure.
4. After WiimotePair reports success, quit it and open Dolphin.
5. Select **Real Wii Remote** for a Wii Remote slot and enable **Continuous
   Scanning**, or use **Refresh**. Press a normal button, such as **A**, to
   reconnect the already paired remote.

Bluetooth permission can be reviewed in **System Settings → Privacy & Security
→ Bluetooth**. Do not type an arbitrary PIN into the macOS Bluetooth settings.
A sensor bar is needed for infrared pointer input, but not for Bluetooth pairing.

## macOS Tahoe pairing workaround

On macOS 26.5, an original `Nintendo RVL-CNT-01` was observed to receive a
Classic pairing request of type 0 (Just Works). IOBluetooth accepted it without
requesting the binary PIN from `devicePairingPINCodeRequest:`, and the attempt
failed with Bluetooth status `0x1F`. Older builds misleadingly displayed this as
`(os/kern) default set` by treating the Bluetooth status as a Mach error.

For this model on macOS 26 and later, WiimotePair temporarily wraps its own
Classic pairing agent delegate and answers the selected remote's type-0 request
through the existing legacy PIN path (type 6). Requests for other peers and
other pairing types are forwarded unchanged, and the original delegate is
restored when the attempt ends. No system service or framework is modified.
The existing PIN callback remains in use on older systems and for other models.

A local build using this workaround was tested on macOS **26.5 (25F71)** with
an original **RVL-CNT-01**. Pairing succeeded, macOS exposed the physical Nintendo
Bluetooth HID device (`057e:0306`), and the tester confirmed that it connected
in **Dolphin 2609a**. This is one hardware configuration; other macOS versions,
Remote Plus models, and third-party remotes have not been hardware-tested here.
The workaround uses private APIs, so future macOS changes may require updates.

## Building and testing

Build the Xcode project with a local ad hoc signature, without a developer team:

```sh
xcodebuild -project WiimotePair.xcodeproj -scheme WiimotePair \
  -configuration Debug -derivedDataPath build \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= analyze build
```

The built application is `build/Build/Products/Debug/WiimotePair.app`.
Delegate regression tests do not open a Bluetooth session:

```sh
./Tests/run-tests.sh
```
