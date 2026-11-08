#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

#define MOTOR    26
#define NAME_PIN 32                 // tie GPIO 32 to GND on the right bracelet; leave open on the left
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

  pinMode(NAME_PIN, INPUT_PULLUP);
  delay(10);
  const char* name = digitalRead(NAME_PIN) == LOW ? "Bracelet-R" : "Bracelet-L";

  BLEDevice::init(name);
  BLEServer* srv = BLEDevice::createServer();
  BLEService* svc = srv->createService(SVC_UUID);
  BLECharacteristic* chr = svc->createCharacteristic(CHR_UUID,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  chr->setCallbacks(new RxCB());
  svc->start();
  srv->getAdvertising()->addServiceUUID(SVC_UUID);
  srv->getAdvertising()->start();
  Serial.print("advertising ");
  Serial.println(name);
}

void loop() {
  unsigned long t = millis();
  if (t - lastCmd > 2000) cue = OFF;          // watchdog: silence if the phone goes quiet

  uint8_t out = 0;
  switch (cue) {
    case FORWARD: out = ((t / 250) % 2 == 0) ? 220 : 0;  break;   // 250 on / 250 off strong pulses
    case STOP:    out = 255;                             break;   // continuous at full
    case TURN:    out = param < 70 ? 70 : param;         break;   // continuous, variable
    default:      out = 0;
  }
  ledcWrite(MOTOR, out);
  delay(5);
}