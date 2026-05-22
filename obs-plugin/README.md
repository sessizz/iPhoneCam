# iPhoneCam OBS Plugin

macOS-only OBS input source for receiving the iPhoneCam UDP/Bonjour H.264 stream directly inside OBS.

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

- Add source type `iPhoneCam` in OBS.
- Keep the standalone Mac receiver app closed while testing, because both advertise `_iphonecam._udp`.
- FPS and bitrate are reported from the iPhone stream; OBS does not control the encoder yet.
