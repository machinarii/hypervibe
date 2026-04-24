# Remotastic

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Control your Mac with your Apple TV Siri Remote — a lightweight menu bar app that turns your Siri Remote into a trackpad and media controller.

## Features

- **Trackpad Control**: Cursor movement, clicking, dragging, and two-finger scrolling
- **Trackpad Modes**: Switch between Cursor Mode and Scroll Mode
- **Customizable Buttons**: Remap any button to media controls, mouse actions, or keyboard shortcuts
- **Multi-Monitor Support**: Works across all displays
- **Menu Bar Integration**: Quick access to settings and connection status

## Installation

**Prerequisites**: macOS 11.0+, Xcode Command Line Tools, Apple TV Siri Remote (tested with model A1513)

```bash
git clone https://github.com/laurentschuermans/Remotastic.git
cd Remotastic
./build.sh
./create_app_bundle.sh
open Remotastic.app
```

**Permissions**: Grant Accessibility permissions in System Settings → Privacy & Security → Accessibility

**Pair Remote**: Hold Menu + Volume Up for 5 seconds, then pair in System Settings → Bluetooth

## Usage

Click the menu bar icon to:
- View connection status
- Configure button mappings
- Toggle trackpad mode (Cursor ↔ Scroll)
- Adjust scroll speed

**Default Mappings**: Play/Pause → Media, Menu → Toggle Mode, Select → Click, Volume → Volume, TV → Right Click, Siri → Space

## Troubleshooting

- **Not connecting**: Check Bluetooth, re-pair remote, restart app
- **Cursor not moving**: Verify Accessibility permissions, check connection status, ensure Cursor Mode
- **Buttons not working**: Check mappings in menu bar, verify connection

## Limitations

- Uses private APIs (not App Store compatible)
- Remote may disconnect after ~90s inactivity (press any button to reconnect)
- Requires Accessibility permissions
- **Tested only with Apple TV Siri Remote model A1513** (other models may work but are untested)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT License - see [LICENSE](LICENSE) for details.
