# ESP32 BLE Zoom Joystick Firmware

Arduino IDE sketch for the ESP32-C3 0.42 OLED board and a KY-023 joystick.

## Arduino IDE Setup

1. Install `esp32 by Espressif Systems` from Boards Manager.
2. Select `ESP32C3 Dev Module` or `ESP32-C3-DevKitM-1` if it is available.
3. Install these libraries from Library Manager:
   - `NimBLE-Arduino`
   - `U8g2`
4. Open `esp32_ble_zoom_joystick/esp32_ble_zoom_joystick.ino`.
5. Verify and upload.

## Wiring

- OLED I2C is on the board: `SDA=GPIO5`, `SCL=GPIO6`.
- KY-023:
  - `VRx -> GPIO0`
  - `VRy -> GPIO1`
  - `SW -> GPIO10`
  - `+5V/VCC -> 3V3`
  - `GND -> GND`

Short press resets zoom. Long press recalibrates the joystick center.

The sketch currently rotates the OLED output 180 degrees and swaps the logical joystick axes for the mounted orientation. If the hardware is remounted later, adjust `kSwapJoystickAxes`, `kInvertX`, `kInvertY`, or the `U8G2_R2` rotation in the sketch.
