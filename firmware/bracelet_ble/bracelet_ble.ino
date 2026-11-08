#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

#define NAME     "Bracelet-R"       // change to Bracelet-L for the left one
#define MOTOR    26
#define SVC_UUID "12345678-1234-5678-1234-56789abcdef0"
#define CHR_UUID "12345678-1234-5678-1234-56789abcdef1"

unsigned long offAt = 0;

class RxCB : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    String v = c->getValue();        // byte0 = intensity 0-255, byte1 = duration in 10 ms units
    if (v.length() < 1) return;
    uint8_t inten = v[0];
    uint8_t dur   = v.length() > 1 ? v[1] : 50;
    ledcWrite(MOTOR, inten);
    offAt = millis() + dur * 10UL;
    Serial.printf("buzz %d for %d ms\n", inten, dur * 10);
  }
};

void setup() {
  Serial.begin(115200);
  ledcAttach(MOTOR, 5000, 8);
  BLEDevice::init(NAME);
  BLEServer* srv = BLEDevice::createServer();
  BLEService* svc = srv->createService(SVC_UUID);
  BLECharacteristic* chr = svc->createCharacteristic(CHR_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  chr->setCallbacks(new RxCB());
  svc->start();
  srv->getAdvertising()->addServiceUUID(SVC_UUID);
  srv->getAdvertising()->start();
  Serial.println("advertising");
}

void loop() {
  if (offAt && millis() > offAt) { ledcWrite(MOTOR, 0); offAt = 0; }
  delay(5);
}