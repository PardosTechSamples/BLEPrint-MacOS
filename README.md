# BLEPrint for macOS

A native macOS app (SwiftUI + CoreBluetooth) for printing labels from your Mac to the
**Nelko® P21** and the **Supvan® / Katasymbol E10** (T10/T15 family) over Bluetooth LE. No phone app
needed.

This is the native companion to [BLEPrint](https://github.com/PardosTechSamples/BLEPrint), the
cross-platform Python version for Windows, Linux and macOS. Both have the same features, and this
app's printer encoders are checked byte-for-byte against the Python ones.

## Features

- **Find printer…**: searches Bluetooth and lists supported printers first. The brand is detected from
  the MAC prefix (OUI), which works on macOS too, then from the device name or its Bluetooth service.
- **Batch print from a CSV**: build a label from a `{Column}` template, preview any row, and print one
  row or the whole file.
- **Print as** text, QR code + text, or QR code only.
- **Fit length to text** (Supvan E10): labels as long as the text, printed edge to edge.
- **Continuous print** (Supvan E10): every label in one job. Without it, BLEPrint pauses after each
  label so you can cut it. Disabled on the Nelko P21 until it has been tested there.

| Printer | Detected by | Protocol |
|---|---|---|
| Nelko P21 | MAC prefix `BE:C0:11`, name `P21…`, service `FF00` | TSPL over BLE, 96-dot (12 mm) head, 203 dpi |
| Supvan E10 / T10 | OUI `A4:93:40` (Beijing Supvan), name `T0xxx…`, service `E0FF…` | `7E 5A` frames + LZMA bitmaps, 96-dot head |

> “Nelko”, “P21”, “Supvan”, “Katasymbol” and “E10” are trademarks of their respective owners, used
> here only to describe compatibility. BLEPrint is not affiliated with either company.

## Download

Get the `BLEPrint-…-macOS-universal.zip` file from [Releases](../../releases). It's a universal app (Apple Silicon + Intel),
macOS 13 or later. Unzip it and move `BLEPrint.app` to Applications.

The app is ad-hoc signed, not notarized, so macOS blocks the first launch: right-click the app and
choose **Open**, or run `xattr -dr com.apple.quarantine /Applications/BLEPrint.app`. Allow Bluetooth
when asked. Close the printer's phone app first, because the printer accepts only one connection at a
time.

## Build from source

Requires macOS 13+ and Xcode (or the Swift toolchain).

```bash
./scripts/build_app.sh        # -> dist/BLEPrint.app
open dist/BLEPrint.app
```

For development, `swift build` builds the app and the self-test, and `swift run BLEPrint` runs it
without bundling (launch from Terminal so macOS grants Bluetooth access).

To check the encoders against the Python implementation, clone
[BLEPrint](https://github.com/PardosTechSamples/BLEPrint) and install its Python dependencies, then:

```bash
.build/debug/bleprint-selftest | python3 scripts/compare_python.py /path/to/BLEPrint
```

`scripts/scan.command` and `scripts/e10.command` exercise the Bluetooth layer from Terminal (scan, and
a test print on a Supvan E10).

## Layout

| Path | What |
|---|---|
| `Sources/BLEPrintCore/` | Protocols (Nelko TSPL, Supvan frames + LZMA), rendering, Bluetooth, drivers, CSV |
| `Sources/BLEPrint/` | SwiftUI app |
| `Sources/SelfTest/` | Encoder self-test and Bluetooth test tool |
| `Sources/CLzma/` | liblzma headers (0BSD) for the liblzma built into macOS |

Protocol notes live in the [BLEPrint repository](https://github.com/PardosTechSamples/BLEPrint/blob/main/PROTOCOL.md).
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for third-party licences.

## Licence

MIT. See [LICENSE](LICENSE).
