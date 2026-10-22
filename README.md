# iPhoneCam

Streams an iPhone camera into OBS or a macOS preview app over Wi-Fi or a USB cable.

## Targets

- `iPhoneCam`: iOS SwiftUI camera app. Captures the back camera at 1080p60 when available, encodes HEVC or H.264 with VideoToolbox, and serves the stream on TCP port 8240, advertised over Bonjour as `_iphonecam._tcp` under the camera name.
- `iPhoneCamReceiver`: macOS SwiftUI receiver. Connects to an iPhone found on the network, an IP address, or (outside the App Sandbox) a USB-attached iPhone, and previews video with `AVSampleBufferDisplayLayer`.
- `iPhoneCamSharedTests`: XCTest coverage for the packet protocol, frame reassembly and the adaptive bitrate policy.
- `obs-plugin`: macOS OBS input source plugin. Dials the iPhone over USB (usbmuxd) or Wi-Fi (IP address or discovered name), decodes with VideoToolbox, and outputs NV12 async video to OBS.
- `firmware/esp32_ble_zoom_joystick`: Arduino IDE firmware for the ESP32-C3 OLED + KY-023 BLE zoom joystick.

## How the stream travels

The iPhone listens and the receivers dial it, the same way over both transports:

- **USB**: the receiver asks `usbmuxd` to connect to port 8240 on the phone. No network needed.
- **Wi-Fi**: the receiver connects to the IP address the app shows on screen (or the camera name found over Bonjour).

Every connection is TCP with `TCP_NODELAY`, so nothing is lost on the way; what keeps it live is on the sending side:

- Each receiver has a bounded queue (12 frames). When it is full, frames are skipped instead of queued, and that
  receiver gets nothing but a keyframe next, so it never decodes a broken reference chain.
- Once a second the sender adapts the bitrate to skipped frames and slow sends. **Balanced** holds the codec target
  (HEVC 8 Mbps, H.264 12 Mbps) and only backs off; **Maximum** probes above it while the link is clean, up to 3.5×
  over USB and 2.5× over Wi-Fi. VideoToolbox applies bitrate cuts live but ignores raises, so a raise starts a new
  encoder session (one keyframe). Thermal pressure halves or quarters the target.
- A receiver that stops reading for 5 s is dropped so it can reconnect instead of holding the bitrate down.
- The phone pings every 2 s and answers clock-sync requests, so receivers detect dead links in 6 s and OBS shows the
  capture-to-decode latency.

## On the iPhone

- **Format** (the `1080p / 60 fps` button on the right edge): camera (back/front), resolution (720p, 1080p, 4K)
  and frame rate (24 to 240 fps, as the camera allows), codec (HEVC/H.264) and quality (Balanced/Maximum).
- **Camera controls** (aperture button): focus (auto, lock, manual distance), exposure (auto, lock, EV bias,
  manual ISO and shutter), white balance (auto, lock, Kelvin, calibrate on white paper or a gray card) and the
  flashlight with its level. Tap the picture to focus and expose there.
- Flashlight and front/back camera also have their own buttons; OBS can drive all of these with hotkeys.
- Tally: a red frame and `ON AIR` while the OBS source is on air, green and `PREVIEW` while it only shows elsewhere.

## First Manual Test

1. Run `iPhoneCam` on a physical iPhone and accept camera, microphone and local network permissions.
2. The app shows `Connect OBS/Mac to <IP> (port 8240)`.
3. In OBS add an `iPhoneCam` source and pick **USB cable**, or **Wi-Fi** with that IP (or the iPhone's name from the list).
4. Or run `iPhoneCamReceiver` on the Mac: **Auto** connects to the first iPhone it finds; you can also type the IP.

The iOS simulator can build the app, but real camera streaming requires a physical iPhone.

## OBS Plugin

See `obs-plugin/README.md` for build instructions. OBS and the Mac receiver can watch the same iPhone at the same time; the phone serves up to four receivers.

## BLE Zoom Joystick

The iOS app can also listen for an ESP32-C3 BLE joystick. The firmware sketch is in `firmware/esp32_ble_zoom_joystick` and shows the current zoom factor plus joystick speed on the board OLED. See `firmware/README.md` for Arduino IDE setup and wiring.

## License

iPhoneCam is free software: you can redistribute it and/or modify it under the terms of the
[GNU General Public License version 2](LICENSE), or (at your option) any later version — the same license as
OBS Studio, whose `libobs` the OBS plugin links against.

Parts of iPhoneCam are adapted from [LensLink](https://github.com/MyNamesEMurray/LensLink) (GPL-2.0-or-later);
files that carry LensLink code say so in a header comment.
