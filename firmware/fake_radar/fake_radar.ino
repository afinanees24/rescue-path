/*
 * fake_radar.ino — FF-RADAR BLE peripheral with SIMULATED LD2410B data.
 *
 * Board:   WEMOS LOLIN32 Lite (ESP32 core by Espressif)
 * Library: NimBLE-Arduino (h2zero), 2.x
 *
 * Advertises as "FF-RADAR" and notifies JSON 5x per second:
 *   {"moving":{"dist":210,"energy":64},"still":{"dist":340,"energy":41}}
 * dist in cm (0 = no target), energy 0-100.
 *
 * Use it to test the iPhone app before the real radar is wired up.
 */

#include <NimBLEDevice.h>

static const char* DEVICE_NAME  = "FF-RADAR";
static const char* SERVICE_UUID = "8E2F0001-6B1D-4C6A-9F3E-2A7C5D9B1E40";
static const char* CHAR_UUID    = "8E2F0002-6B1D-4C6A-9F3E-2A7C5D9B1E40";
static const uint32_t PERIOD_MS = 200;  // 5 Hz

static NimBLEServer* server = nullptr;
static NimBLECharacteristic* radarChar = nullptr;

static void startBle() {
  NimBLEDevice::init(DEVICE_NAME);
  NimBLEDevice::setMTU(185);  // iPhone negotiates a large MTU, so a whole JSON fits in one notify

  server = NimBLEDevice::createServer();
  NimBLEService* service = server->createService(SERVICE_UUID);
  radarChar = service->createCharacteristic(CHAR_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  radarChar->setValue("{}");
  service->start();

  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  NimBLEAdvertisementData advData;
  advData.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
  advData.setCompleteServices(NimBLEUUID(SERVICE_UUID));
  adv->setAdvertisementData(advData);
  NimBLEAdvertisementData scanData;  // name goes in the scan response
  scanData.setName(DEVICE_NAME);
  adv->setScanResponseData(scanData);
  adv->start();
  Serial.println("Advertising as FF-RADAR");
}

static void keepAdvertising() {
  // Restart advertising after the phone disconnects (works on NimBLE 1.x and 2.x).
  if (server->getConnectedCount() == 0 && !NimBLEDevice::getAdvertising()->isAdvertising()) {
    NimBLEDevice::startAdvertising();
  }
}

static int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

void setup() {
  Serial.begin(115200);
  delay(200);
  randomSeed(esp_random());
  startBle();
}

void loop() {
  static uint32_t last = 0;
  keepAdvertising();
  if (millis() - last < PERIOD_MS) { delay(5); return; }
  last = millis();

  float t = millis() / 1000.0f;

  // Moving person walking back and forth between ~1.5 m and ~4.5 m;
  // gone for 4 s out of every 20 s (walked out of view).
  int movingDist = 0, movingEnergy = 0;
  if (fmodf(t, 20.0f) < 16.0f) {
    movingDist = (int)(300 + 150 * sinf(t * 0.6f)) + random(-8, 9);
    movingEnergy = clampi((int)(60 + 20 * sinf(t * 1.3f)) + random(-6, 7), 5, 100);
  }

  // Still person (lying down) at ~3.4 m with breathing jitter;
  // briefly lost for 2 s out of every 30 s.
  int stillDist = 0, stillEnergy = 0;
  if (fmodf(t, 30.0f) < 28.0f) {
    stillDist = 340 + (int)(3 * sinf(t * 1.6f)) + random(-4, 5);
    stillEnergy = clampi(41 + random(-5, 6), 5, 100);
  }

  char json[96];
  int len = snprintf(json, sizeof(json),
                     "{\"moving\":{\"dist\":%d,\"energy\":%d},\"still\":{\"dist\":%d,\"energy\":%d}}",
                     movingDist, movingEnergy, stillDist, stillEnergy);
  radarChar->setValue((const uint8_t*)json, (size_t)len);
  if (server->getConnectedCount() > 0) {
    radarChar->notify();
  }
  Serial.println(json);
}
