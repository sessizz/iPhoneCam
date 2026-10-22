# iPhoneCam OBS Plugin

macOS-only OBS input source that receives the iPhoneCam stream directly inside OBS, over a USB cable or Wi-Fi.

## Build

OBS.app ships `libobs.framework`, but not the development headers. Clone the matching OBS Studio source tree and point CMake at it:

```sh
git clone --depth 1 --branch 32.1.2 https://github.com/obsproject/obs-studio.git /tmp/obs-studio-32.1.2
git clone --depth 1 https://github.com/simd-everywhere/simde.git /tmp/simde
cmake -S obs-plugin -B build/obs-plugin \
  -DOBS_APP_PATH=/Applications/OBS.app \
  -DOBS_SOURCE_DIR=/tmp/obs-studio-32.1.2 \
  -DSIMDE_INCLUDE_DIR=/tmp/simde
cmake --build build/obs-plugin
ctest --test-dir build/obs-plugin --output-on-failure
```

The plugin bundle is produced as `build/obs-plugin/iphonecam-obs.plugin`.

## v1 Notes

- Add source type `iPhoneCam` in OBS and choose a **Connection**:
  - **USB cable**: dials the first iPhone running iPhoneCam through `usbmuxd`, or the one named in **Target iPhone**
    (pin names to keep several iPhones on fixed sources).
  - **Wi-Fi**: type the IP address the app shows (`192.168.1.23`, optionally `:port`) or pick the iPhone by name from
    the list; a name keeps working when the phone's IP changes. The source redials every second until the phone
    answers and reconnects on its own after a drop.
- The stats show the connection, the capture-to-decode latency (measured with a clock sync against the phone) and
  the clock round trip.
- Bind the `iPhoneCam: Zoom In Slow/Medium/Fast`, `iPhoneCam: Zoom Out Slow/Medium/Fast`, and
  `iPhoneCam: Reset Zoom` actions in OBS Settings > Hotkeys. Press-and-hold zoom keys ramp the iPhone lens;
  releasing the key stops the ramp.
- Image hotkeys in the same place: `Toggle Flashlight`, `Switch Front/Back Camera`, `Lock/Unlock Focus and
  Exposure`, `Exposure +` / `Exposure -` (a third of a stop; ISO in manual exposure), `Lock/Unlock White Balance`,
  and `Focus, Exposure and White Balance to Auto`.
- Tally: the iPhone frames its screen red (`ON AIR`) while the source is in the program output and green
  (`PREVIEW`) while it is only showing elsewhere, such as the studio-mode preview or a projector.
- FPS and bitrate are reported from the iPhone stream; OBS does not control the encoder yet.
- After a lost frame or a decode error the source holds the last good frame and asks the iPhone for a keyframe
  (at most every 250 ms) instead of decoding a broken reference chain.
