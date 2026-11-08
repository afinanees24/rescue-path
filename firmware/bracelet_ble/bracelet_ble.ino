#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

#define NAME     "Bracelet-L"       // Bracelet-L for the left one
#define MOTOR    26
#define SVC_UUID "12345678-1234-5678-1234-56789abcdef0"
#define CHR_UUID "12345678-1234-5678-1234-56789abcdef1"

enum Cue : uint8_t { OFF = 0, FORWARD = 1, STOP = 2, TURN = 3 };
volatile uint8_t cue = OFF, param = 0;
volatile unsigned long lastCmd = 0;

class RxCB : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    String v = c->getValue();
    if (v.length() < 1) return;
    cue   = v[0];
    param = v.length() > 1 ? v[1] : 0;
    lastCmd = millis();
    Serial.printf("cue %d param %d\n", cue, param);
  }
};

void setup() {
  Serial.begin(115200);
  ledcAttach(MOTOR, 5000, 8);
  BLEDevice::init(NAME);
  BLEServer* srv = BLEDevice::createServer();
  BLEService* svc = srv->createService(SVC_UUID);
  BLECharacteristic* chr = svc->createCharacteristic(CHR_UUID,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  chr->setCallbacks(new RxCB());
  svc->start();
  srv->getAdvertising()->addServiceUUID(SVC_UUID);
  srv->getAdvertising()->start();
  Serial.println("advertising");
}

void loop() {
  unsigned long t = millis();
  if (t - lastCmd > 2000) cue = OFF;          // watchdog: silence if the phone goes quiet

  uint8_t out = 0;
  switch (cue) {
    case FORWARD: out = ((t / 50) % 2 == 0) ? 150 : 0;   break;   // 50 on / 50 off flutter
    case STOP:    out = ((t % 500) < 300)   ? 255 : 0;   break;   // 300 hard / 200 off
    case TURN:    out = param < 70 ? 70 : param;         break;   // continuous, variable
    default:      out = 0;
  }
  ledcWrite(MOTOR, out);
  delay(5);
}