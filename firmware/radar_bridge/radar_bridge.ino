/*
 * radar_bridge.ino — FF-RADAR BLE peripheral fed by a REAL HLK-LD2410B.
 *
 * Board:     WEMOS LOLIN32 Lite (ESP32 core by Espressif)
 * Libraries: NimBLE-Arduino (h2zero) 2.x, ld2410 (ncmreynolds)
 *
 * Wiring (see README.md):
 *   LD2410B VCC -> 5V supply      LD2410B GND -> GND (shared with ESP32)
 *   LD2410B TX  -> ESP32 GPIO16 (UART2 RX)
 *   LD2410B RX  -> ESP32 GPIO17 (UART2 TX)
 *
 * Same BLE service as fake_radar.ino: advertises as "FF-RADAR" and notifies 5x/s:
 *   {"moving":{"dist":210,"energy":64},"still":{"dist":340,"energy":41}}
 * dist in cm (0 = no target), energy 0-100.
 */

#include <NimBLEDevice.h>
#include <ld2410.h>

static const char* DEVICE_NAME  = "FF-RADAR";
static const char* SERVICE_UUID = "8E2F0001-6B1D-4C6A-9F3E-2A7C5D9B1E40";
static const char* CHAR_UUID    = "8E2F0002-6B1D-4C6A-9F3E-2A7C5D9B1E40";
static const uint32_t PERIOD_MS = 200;  // 5 Hz

#define RADAR_RX_PIN 16   // ESP32 receives on this pin  <- LD2410B TX
#define RADAR_TX_PIN 17   // ESP32 transmits on this pin -> LD2410B RX
#define RADAR_BAUD   256000

static NimBLEServer* server = nullptr;
static NimBLECharacteristic* radarChar = nullptr;
static ld2410 radar;

static void startBle() {
  NimBLEDevice::init(DEVICE_NAME);
  NimBLEDevice::setMTU(185);

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
  NimBLEAdvertisementData scanData;
  scanData.setName(DEVICE_NAME);
  adv->setScanResponseData(scanData);
  adv->start();
  Serial.println("Advertising as FF-RADAR");
}

static void keepAdvertising() {
  if (server->getConnectedCount() == 0 && !NimBLEDevice::getAdvertising()->isAdvertising()) {
    NimBLEDevice::startAdvertising();
  }
}

void setup() {
  Serial.begin(115200);
  delay(200);

  Serial2.begin(RADAR_BAUD, SERIAL_8N1, RADAR_RX_PIN, RADAR_TX_PIN);
  delay(500);
  Serial.print("LD2410B: ");
  if (radar.begin(Serial2)) {
    Serial.println("connected");
  } else {
    Serial.println("NOT responding - check 5V, GND and that TX/RX are crossed");
  }

  startBle();
}

void loop() {
  static uint32_t last = 0;
  radar.read();  // call as often as possible to keep up with the UART stream
  keepAdvertising();
  if (millis() - last < PERIOD_MS) return;
  last = millis();

  int movingDist = 0, movingEnergy = 0, stillDist = 0, stillEnergy = 0;
  if (radar.isConnected()) {
    if (radar.movingTargetDetected()) {
      movingDist = radar.movingTargetDistance();
      movingEnergy = radar.movingTargetEnergy();
    }
    if (radar.stationaryTargetDetected()) {
      stillDist = radar.stationaryTargetDistance();
      stillEnergy = radar.stationaryTargetEnergy();
    }
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
