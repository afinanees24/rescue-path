#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#define SVC_UUID "12345678-1234-5678-1234-56789abcdef0"
#define CHR_UUID "12345678-1234-5678-1234-56789abcdef2"   // waist sensor stream
const int TRIG = 14, ECHO = 27;
const bool FAKE_RADAR = true;        // flip to false when LD2410 is wired
BLECharacteristic* chr; bool connected = false;

class SrvCB : public BLEServerCallbacks {
  void onConnect(BLEServer*) override { connected = true; }
  void onDisconnect(BLEServer* s) override { connected = false; s->getAdvertising()->start(); }
};

float readCm() {
  digitalWrite(TRIG, LOW);  delayMicroseconds(2);
  digitalWrite(TRIG, HIGH); delayMicroseconds(10);
  digitalWrite(TRIG, LOW);
  long us = pulseIn(ECHO, HIGH, 30000);
  return us == 0 ? -1 : us / 58.0;
}

void readRadar(int& present, int& dist, int& energy) {
  if (FAKE_RADAR) {                  // moving numbers so the UI has something to draw
    float t = millis() / 1000.0;
    energy  = 50 + 45 * sin(t);
    present = energy > 40;
    dist    = 150 + 100 * sin(t / 3);
    return;
  }
  // TODO: parse LD2410 on Serial2 here
}

void setup() {
  Serial.begin(115200);
  pinMode(TRIG, OUTPUT); pinMode(ECHO, INPUT); digitalWrite(TRIG, LOW);
  if (!FAKE_RADAR) Serial2.begin(256000, SERIAL_8N1, 16, 17);
  BLEDevice::init("Waist");
  BLEDevice::setMTU(185);
  BLEServer* srv = BLEDevice::createServer(); srv->setCallbacks(new SrvCB());
  BLEService* svc = srv->createService(SVC_UUID);
  chr = svc->createCharacteristic(CHR_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  chr->addDescriptor(new BLE2902());
  svc->start();
  srv->getAdvertising()->addServiceUUID(SVC_UUID);
  srv->getAdvertising()->start();
  Serial.println("Waist advertising");
}

void loop() {
  int p, d, e; readRadar(p, d, e);
  float cm = readCm();
  char buf[80];
  snprintf(buf, sizeof buf, "{\"us\":%.0f,\"rp\":%d,\"rd\":%d,\"re\":%d}", cm, p, d, e);
  if (connected) { chr->setValue(buf); chr->notify(); }
  Serial.println(buf);
  delay(100);                        // 10 Hz
}