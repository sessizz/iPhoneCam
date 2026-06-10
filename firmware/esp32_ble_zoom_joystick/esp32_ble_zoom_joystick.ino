#include <Arduino.h>
#include <NimBLEDevice.h>
#include <U8g2lib.h>
#include <Wire.h>

namespace {

constexpr char kDeviceName[] = "iPhoneCam Zoom";
constexpr char kServiceUUID[] = "7D2F6C7E-1B2F-4B3A-9E23-55F2C66B71A0";
constexpr char kJoystickCharacteristicUUID[] = "7D2F6C7E-1B2F-4B3A-9E23-55F2C66B71A1";
constexpr char kDisplayCharacteristicUUID[] = "7D2F6C7E-1B2F-4B3A-9E23-55F2C66B71A2";

constexpr uint8_t kOLEDDataPin = 5;
constexpr uint8_t kOLEDClockPin = 6;
constexpr uint8_t kJoystickXPin = 0;
constexpr uint8_t kJoystickYPin = 1;
constexpr uint8_t kJoystickButtonPin = 10;
constexpr bool kSwapJoystickAxes = true;
constexpr bool kInvertX = true;
constexpr bool kInvertY = false;

constexpr uint16_t kADCMax = 4095;
constexpr uint32_t kJoystickPeriodMs = 40;
constexpr uint32_t kDisplayPeriodMs = 150;
constexpr uint32_t kDisplayTimeoutMs = 750;
constexpr uint32_t kDebounceMs = 35;
constexpr uint32_t kLongPressMs = 1200;
constexpr uint8_t kJoystickFlagResetZoom = 1 << 0;
constexpr uint8_t kJoystickFlagCalibrated = 1 << 1;
constexpr uint8_t kDisplayFlagConnected = 1 << 0;
constexpr uint8_t kDisplayFlagZooming = 1 << 1;

struct __attribute__((packed)) JoystickReportV1 {
  uint8_t version;
  uint8_t flags;
  int16_t x;
  int16_t y;
  uint16_t sequence;
};

struct __attribute__((packed)) DisplayStateV1 {
  uint8_t version;
  uint8_t flags;
  uint16_t zoomCenti;
  int8_t signedSpeedPercent;
  uint8_t reserved;
  uint16_t sequence;
};

U8G2_SSD1306_72X40_ER_F_HW_I2C u8g2(U8G2_R2, U8X8_PIN_NONE, kOLEDClockPin, kOLEDDataPin);
NimBLECharacteristic *joystickCharacteristic = nullptr;

bool bleConnected = false;
bool buttonStablePressed = false;
bool buttonLastReading = false;
bool pendingResetZoom = false;
bool centerCalibrated = false;
uint16_t centerX = 2048;
uint16_t centerY = 2048;
uint16_t joystickSequence = 0;
uint32_t lastJoystickAt = 0;
uint32_t lastDisplayAt = 0;
uint32_t lastButtonChangeAt = 0;
uint32_t buttonDownAt = 0;
uint32_t calibrationNoticeUntil = 0;
uint32_t displayStateReceivedAt = 0;
DisplayStateV1 displayState = {1, 0, 100, 0, 0, 0};

int16_t normalizedAxis(uint16_t raw, uint16_t center, bool invert) {
  const int32_t delta = int32_t(raw) - int32_t(center);
  const int32_t denominator = delta >= 0 ? max<int32_t>(1, int32_t(kADCMax) - int32_t(center)) : max<int32_t>(1, int32_t(center));
  float normalized = float(delta) / float(denominator);
  normalized = constrain(normalized, -1.0f, 1.0f);
  if (invert) {
    normalized = -normalized;
  }
  return int16_t(lroundf(normalized * 32767.0f));
}

uint16_t averagedAnalogRead(uint8_t pin, uint8_t samples = 24) {
  uint32_t total = 0;
  for (uint8_t index = 0; index < samples; ++index) {
    total += analogRead(pin);
    delay(2);
  }
  return uint16_t(total / samples);
}

void calibrateCenter() {
  centerX = averagedAnalogRead(kJoystickXPin, 48);
  centerY = averagedAnalogRead(kJoystickYPin, 48);
  centerCalibrated = true;
  calibrationNoticeUntil = millis() + 1000;
}

void updateButton() {
  const uint32_t now = millis();
  const bool readingPressed = digitalRead(kJoystickButtonPin) == LOW;
  if (readingPressed != buttonLastReading) {
    buttonLastReading = readingPressed;
    lastButtonChangeAt = now;
  }

  if (now - lastButtonChangeAt < kDebounceMs || readingPressed == buttonStablePressed) {
    return;
  }

  buttonStablePressed = readingPressed;
  if (buttonStablePressed) {
    buttonDownAt = now;
    return;
  }

  const uint32_t pressDuration = now - buttonDownAt;
  if (pressDuration >= kLongPressMs) {
    calibrateCenter();
  } else {
    pendingResetZoom = true;
  }
}

void notifyJoystickIfNeeded() {
  if (!bleConnected || joystickCharacteristic == nullptr) {
    return;
  }

  const uint32_t now = millis();
  if (now - lastJoystickAt < kJoystickPeriodMs) {
    return;
  }
  lastJoystickAt = now;

  JoystickReportV1 report;
  report.version = 1;
  report.flags = centerCalibrated ? kJoystickFlagCalibrated : 0;
  if (pendingResetZoom) {
    report.flags |= kJoystickFlagResetZoom;
    pendingResetZoom = false;
  }
  const int16_t physicalX = normalizedAxis(analogRead(kJoystickXPin), centerX, kInvertX);
  const int16_t physicalY = normalizedAxis(analogRead(kJoystickYPin), centerY, kInvertY);
  report.x = kSwapJoystickAxes ? physicalY : physicalX;
  report.y = kSwapJoystickAxes ? physicalX : physicalY;
  report.sequence = ++joystickSequence;

  joystickCharacteristic->setValue(reinterpret_cast<uint8_t *>(&report), sizeof(report));
  joystickCharacteristic->notify();
}

void drawDisplay() {
  const uint32_t now = millis();
  if (now - lastDisplayAt < kDisplayPeriodMs) {
    return;
  }
  lastDisplayAt = now;

  const bool displayFresh = now - displayStateReceivedAt <= kDisplayTimeoutMs;
  char line1[24] = {};
  char line2[24] = {};

  if (calibrationNoticeUntil > now) {
    snprintf(line1, sizeof(line1), "OK");
    snprintf(line2, sizeof(line2), "CENTER");
  } else if (!bleConnected) {
    snprintf(line1, sizeof(line1), "--");
    snprintf(line2, sizeof(line2), "BLE");
  } else if (!displayFresh) {
    snprintf(line1, sizeof(line1), "--");
    snprintf(line2, sizeof(line2), "WAIT");
  } else {
    snprintf(line1, sizeof(line1), "%u.%02ux", displayState.zoomCenti / 100, displayState.zoomCenti % 100);
    snprintf(line2, sizeof(line2), "%+d%%", displayState.signedSpeedPercent);
  }

  u8g2.clearBuffer();
  u8g2.setFont(u8g2_font_logisoso18_tn);
  u8g2.drawStr((72 - u8g2.getStrWidth(line1)) / 2, 21, line1);
  u8g2.setFont(u8g2_font_9x15B_tr);
  u8g2.drawStr((72 - u8g2.getStrWidth(line2)) / 2, 39, line2);
  u8g2.sendBuffer();
}

class DisplayCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *characteristic, NimBLEConnInfo &) override {
    const NimBLEAttValue value = characteristic->getValue();
    if (value.length() < sizeof(DisplayStateV1)) {
      return;
    }
    memcpy(&displayState, value.data(), sizeof(DisplayStateV1));
    if (displayState.version == 1) {
      displayStateReceivedAt = millis();
    }
  }
};

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *, NimBLEConnInfo &) override {
    bleConnected = true;
  }

  void onDisconnect(NimBLEServer *, NimBLEConnInfo &, int) override {
    bleConnected = false;
    displayState.flags = 0;
    displayState.signedSpeedPercent = 0;
    NimBLEDevice::startAdvertising();
  }
};

void startBLE() {
  NimBLEDevice::init(kDeviceName);
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);

  NimBLEServer *server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  NimBLEService *service = server->createService(kServiceUUID);
  joystickCharacteristic = service->createCharacteristic(
      kJoystickCharacteristicUUID,
      NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);

  NimBLECharacteristic *displayCharacteristic = service->createCharacteristic(
      kDisplayCharacteristicUUID,
      NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  displayCharacteristic->setCallbacks(new DisplayCallbacks());

  service->start();

  NimBLEAdvertising *advertising = NimBLEDevice::getAdvertising();
  advertising->addServiceUUID(kServiceUUID);
  advertising->setName(kDeviceName);
  advertising->start();
}

} // namespace

void setup() {
  pinMode(kJoystickButtonPin, INPUT_PULLUP);
  analogReadResolution(12);
  Wire.begin(kOLEDDataPin, kOLEDClockPin);
  u8g2.begin();
  calibrateCenter();
  startBLE();
}

void loop() {
  updateButton();
  notifyJoystickIfNeeded();
  drawDisplay();
  delay(5);
}
