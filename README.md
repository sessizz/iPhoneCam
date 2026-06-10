# iPhoneCam

MVP for streaming one iPhone camera to a macOS preview app over the local network.

## Targets

- `iPhoneCamReceiver`: macOS SwiftUI receiver. Starts a UDP listener, advertises `_iphonecam._udp.`, reassembles H.264 frame fragments, and previews video with `AVSampleBufferDisplayLayer`.
- `iPhoneCam`: iOS SwiftUI camera client. Captures the back camera at 1080p60 when available, encodes H.264 with VideoToolbox, discovers the Mac receiver with Bonjour, and sends UDP fragments.
- `iPhoneCamSharedTests`: XCTest coverage for packet encoding and frame reassembly.
- `obs-plugin`: macOS OBS input source plugin. Advertises the same Bonjour service, receives the iPhone stream directly, decodes H.264 with VideoToolbox, and outputs NV12 async video to OBS.
- `firmware/esp32_ble_zoom_joystick`: Arduino IDE firmware for the ESP32-C3 OLED + KY-023 BLE zoom joystick.

## First Manual Test

1. Run `iPhoneCamReceiver` on the Mac.
2. Run `iPhoneCam` on a physical iPhone on the same local network.
3. Accept camera and local network permissions.
4. The iPhone should auto-discover the Mac receiver and start streaming.

The iOS simulator can build the app, but real camera streaming requires a physical iPhone.

## OBS Plugin

See `obs-plugin/README.md` for build instructions. Keep the standalone Mac receiver closed while testing the OBS source, because both advertise `_iphonecam._udp.`.

## BLE Zoom Joystick

The iOS app can also listen for an ESP32-C3 BLE joystick. The firmware sketch is in `firmware/esp32_ble_zoom_joystick` and shows the current zoom factor plus joystick speed on the board OLED. See `firmware/README.md` for Arduino IDE setup and wiring.
