/*
 * LifeSpan TR1000-DT ESP32 console — v2
 *
 * Modbus RTU master on the treadmill bus + BLE FTMS treadmill server.
 *
 * Bus (verified 2026-07-06):
 *   orange = MCB's RX  -> our TX, GPIO16 via shifter HV1/LV1
 *   yellow = MCB's TX  -> our RX, GPIO17 via shifter HV2/LV2
 *   4800 8N1, slave 0x01. Separate point-to-point lines, no echo.
 *   red = base 5V -> shifter HV. brown+blue bridged = motor-enable loop.
 *
 * Registers: 0x0001 w1=start | 0x0002 w1=stop | 0x000A speed setpoint
 * (value = 146.03 * km/h, 50 = stopped) | 0x000F steps (w0 = reset) |
 * 0x0101 version (0x2001) | 0xD10A actual speed.
 *
 * BLE: standard FTMS (0x1826) — Treadmill Data notify @1Hz, Control Point
 * (request control / start / stop / set target speed), Machine Status.
 * Custom service exposes the base's step count (uint32 notify).
 *
 * Serial console (115200): s=start x=stop 1..6=km/h +/-=0.1km/h p=poll d=dump
 */

#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "driver/gpio.h"

#define PIN_RX 17
#define PIN_TX 16
#define BUS_BAUD 4800
#define POLL_INTERVAL_MS 100
#define RESPONSE_TIMEOUT_MS 120
#define INTERFRAME_MS 8

#define KMH_TO_VALUE 146.03f  // protocol value = 235*mph = 146.03*km/h
#define IDLE_VALUE 50
#define MIN_KMH 0.8f
#define MAX_KMH 6.4f
#define COMMS_WATCHDOG_MS 3000
#define MAX_SESSION_S (4 * 3600)

HardwareSerial bus(2);

// ---- treadmill state (loop task owns it; BLE callbacks post requests) ----
float targetKmh = 2.0f;
bool beltRunning = false;
float actualKmh = 0;
uint32_t steps = 0;
double distanceM = 0;
uint32_t elapsedS = 0;
uint32_t okResponses = 0, timeouts = 0, crcErrors = 0;
uint32_t lastGoodReplyMs = 0;
uint32_t lastAnyReplyMs = 0;  // ANY bytes from MCB — even corrupt = alive

// requests posted from BLE callbacks, consumed by loop
volatile bool reqStart = false, reqStop = false, reqSpeedPending = false;
volatile float reqSpeedKmh = 0;
// control-point response, sent from loop — NEVER indicate() inside the BLE
// callback: under a burst of writes that deadlocks the BT task against
// loop()'s notify(), freezing the whole firmware (observed live).
volatile bool cpRespPending = false;
volatile uint8_t cpRespOp = 0, cpRespResult = 0;

bool polling = true;
bool hexDump = false;
uint8_t pollPhase = 0;
uint32_t lastPoll = 0, lastTick = 0, lastNotify = 0;

// ---- BLE handles ----
BLECharacteristic *chData, *chControl, *chStatus, *chSteps;
bool bleConnected = false;

// ------------------------------------------------------------- Modbus CRC
uint16_t modbusCRC(const uint8_t *buf, uint8_t len) {
  uint16_t crc = 0xFFFF;
  for (uint8_t i = 0; i < len; i++) {
    crc ^= buf[i];
    for (uint8_t b = 0; b < 8; b++)
      crc = (crc & 1) ? (crc >> 1) ^ 0xA001 : crc >> 1;
  }
  return crc;
}

void printHex(const char *tag, const uint8_t *buf, uint8_t len) {
  Serial.printf("%s", tag);
  for (uint8_t i = 0; i < len; i++) Serial.printf(" %02X", buf[i]);
  Serial.println();
}

// ------------------------------------------------------------ transaction
uint8_t transact(uint8_t func, uint16_t reg, uint16_t val,
                 uint8_t *resp, uint8_t respMax) {
  uint8_t frame[8] = {
    0x01, func, (uint8_t)(reg >> 8), (uint8_t)(reg & 0xFF),
    (uint8_t)(val >> 8), (uint8_t)(val & 0xFF), 0, 0
  };
  uint16_t crc = modbusCRC(frame, 6);
  frame[6] = crc & 0xFF;
  frame[7] = crc >> 8;

  while (bus.available()) bus.read();
  delay(INTERFRAME_MS);
  if (hexDump) printHex("TX:", frame, 8);
  bus.write(frame, 8);
  bus.flush();

  uint8_t len = 0;
  uint32_t t0 = millis(), lastByte = millis();
  while (millis() - t0 < RESPONSE_TIMEOUT_MS) {
    if (bus.available()) {
      if (len < respMax) resp[len++] = bus.read(); else bus.read();
      lastByte = millis();
    } else if (len > 0 && millis() - lastByte > 12) break;
  }
  if (len == 0) { timeouts++; return 0; }
  lastAnyReplyMs = millis();
  if (hexDump) printHex("RX:", resp, len);
  if (len < 5) { crcErrors++; return 0; }
  uint16_t rcrc = modbusCRC(resp, len - 2);
  if ((resp[len - 2] != (rcrc & 0xFF)) || (resp[len - 1] != (rcrc >> 8))) {
    crcErrors++;
    return 0;
  }
  okResponses++;
  lastGoodReplyMs = millis();
  return len;
}

uint16_t kmhToValue(float kmh) { return (uint16_t)(kmh * KMH_TO_VALUE + 0.5f); }

// --------------------------------------------------------------- FTMS bits
void notifyStatus(uint8_t op, int16_t param = -1) {
  if (!bleConnected) return;
  uint8_t p[3] = { op, 0, 0 };
  int n = 1;
  if (param >= 0) { p[1] = param & 0xFF; p[2] = param >> 8; n = 3; }
  chStatus->setValue(p, n);
  chStatus->notify();
}

void startBelt() {
  Serial.println(">> START");
  uint8_t r[24];
  transact(0x06, 0x000F, 0x0000, r, sizeof(r));  // reset step counter
  transact(0x06, 0x0001, 0x0001, r, sizeof(r));  // start
  if (targetKmh < MIN_KMH) targetKmh = MIN_KMH;
  transact(0x06, 0x000A, kmhToValue(targetKmh), r, sizeof(r));  // speed now
  distanceM = 0;
  elapsedS = 0;
  steps = 0;
  beltRunning = true;
  notifyStatus(0x04);  // started/resumed
}

void stopBelt() {
  Serial.println(">> STOP");
  uint8_t r[24];
  transact(0x06, 0x0002, 0x0001, r, sizeof(r));
  beltRunning = false;
  notifyStatus(0x02, 0x01);  // stopped by user
}

void setSpeed(float kmh) {
  targetKmh = constrain(kmh, MIN_KMH, MAX_KMH);
  Serial.printf(">> speed %.2f km/h\n", targetKmh);
  notifyStatus(0x05, (uint16_t)(targetKmh * 100));  // target speed changed
}

// FTMS Treadmill Data: flags [dist present | elapsed present], speed u16
// (0.01 km/h), distance u24 (m), elapsed u16 (s)
void notifyTreadmillData() {
  if (!bleConnected) return;
  uint16_t sp = (uint16_t)(actualKmh * 100 + 0.5f);
  uint32_t dm = (uint32_t)distanceM;
  uint16_t el = (uint16_t)min(elapsedS, (uint32_t)0xFFFF);
  uint8_t p[9] = {
    0x04, 0x04,                                   // flags 0x0404
    (uint8_t)sp, (uint8_t)(sp >> 8),
    (uint8_t)dm, (uint8_t)(dm >> 8), (uint8_t)(dm >> 16),
    (uint8_t)el, (uint8_t)(el >> 8)
  };
  chData->setValue(p, sizeof(p));
  chData->notify();
  uint8_t s4[4] = { (uint8_t)steps, (uint8_t)(steps >> 8),
                    (uint8_t)(steps >> 16), (uint8_t)(steps >> 24) };
  chSteps->setValue(s4, 4);
  chSteps->notify();
}

class ServerCB : public BLEServerCallbacks {
  void onConnect(BLEServer *) override {
    bleConnected = true;
    Serial.println("[ble] connected");
  }
  void onDisconnect(BLEServer *) override {
    bleConnected = false;
    Serial.println("[ble] disconnected — advertising again");
    BLEDevice::startAdvertising();
  }
};

class ControlCB : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) override {
    String v = c->getValue();
    if (v.length() == 0) return;
    uint8_t op = v[0];
    uint8_t result = 0x01;  // success
    Serial.printf("[ble] CP op=%02X len=%d t=%lu\n", op, v.length(), millis());
    switch (op) {
      case 0x00: break;  // request control — always granted
      case 0x01:         // reset
        reqStop = true;
        break;
      case 0x02:         // set target speed, uint16 0.01 km/h
        if (v.length() >= 3) {
          reqSpeedKmh = ((uint8_t)v[1] | ((uint8_t)v[2] << 8)) / 100.0f;
          reqSpeedPending = true;
        } else result = 0x03;  // invalid parameter
        break;
      case 0x07: reqStart = true; break;
      case 0x08: reqStop = true; break;
      default: result = 0x02;  // not supported
    }
    cpRespOp = op;
    cpRespResult = result;
    cpRespPending = true;  // loop() sends the indication
  }
};

void setupBLE() {
  BLEDevice::init("LifeSpan TR1000");
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCB());

  BLEService *ftms = server->createService(BLEUUID((uint16_t)0x1826));

  BLECharacteristic *chFeature = ftms->createCharacteristic(
    BLEUUID((uint16_t)0x2ACC), BLECharacteristic::PROPERTY_READ);
  // machine features: total distance (bit2); target features: speed (bit0)
  uint8_t feat[8] = { 0x04, 0, 0, 0, 0x01, 0, 0, 0 };
  chFeature->setValue(feat, 8);

  chData = ftms->createCharacteristic(
    BLEUUID((uint16_t)0x2ACD), BLECharacteristic::PROPERTY_NOTIFY);
  chData->addDescriptor(new BLE2902());

  chControl = ftms->createCharacteristic(
    BLEUUID((uint16_t)0x2AD9),
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR |
    BLECharacteristic::PROPERTY_INDICATE);
  chControl->addDescriptor(new BLE2902());
  chControl->setCallbacks(new ControlCB());

  chStatus = ftms->createCharacteristic(
    BLEUUID((uint16_t)0x2ADA), BLECharacteristic::PROPERTY_NOTIFY);
  chStatus->addDescriptor(new BLE2902());

  ftms->start();

  BLEService *custom = server->createService(
    "7C9A0001-3D3A-4E7B-8A10-25C1D9E0F2A4");
  chSteps = custom->createCharacteristic(
    "7C9A0002-3D3A-4E7B-8A10-25C1D9E0F2A4",
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  chSteps->addDescriptor(new BLE2902());
  custom->start();

  BLEAdvertising *adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(BLEUUID((uint16_t)0x1826));
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();
  Serial.println("[ble] FTMS advertising as 'LifeSpan TR1000'");
}

// ------------------------------------------------------------------ setup
void setup() {
  Serial.begin(115200);
  bus.begin(BUS_BAUD, SERIAL_8N1, PIN_RX, PIN_TX);
  gpio_pullup_en((gpio_num_t)PIN_RX);
  delay(300);

  Serial.println("\nLifeSpan TR1000 console v2 — Modbus + FTMS");
  const uint8_t known[] = { 0x01, 0x06, 0x00, 0x0A, 0x00, 0x32 };
  uint16_t c = modbusCRC(known, 6);
  Serial.printf("CRC self-test: %s\n", c == 0x1D28 ? "OK" : "** FAIL **");

  setupBLE();
  lastGoodReplyMs = millis();
}

// ------------------------------------------------------------------- loop
void loop() {
  // ---- send deferred control-point ack ----
  if (cpRespPending) {
    cpRespPending = false;
    uint8_t resp[3] = { 0x80, cpRespOp, cpRespResult };
    chControl->setValue(resp, 3);
    if (bleConnected) chControl->indicate();
  }

  // ---- consume BLE requests (apply speed IMMEDIATELY, don't wait for the
  // poll rotation — that cost up to 400ms of perceived lag) ----
  if (reqStart) { reqStart = false; if (!beltRunning) startBelt(); }
  if (reqStop) { reqStop = false; if (beltRunning) stopBelt(); }
  if (reqSpeedPending) {
    reqSpeedPending = false;
    setSpeed(reqSpeedKmh);
    if (beltRunning) {
      uint8_t r[24];
      transact(0x06, 0x000A, kmhToValue(targetKmh), r, sizeof(r));
    }
  }

  // ---- serial console ----
  while (Serial.available()) {
    char ch = Serial.read();
    switch (ch) {
      case 's': startBelt(); break;
      case 'x': stopBelt(); break;
      case '+': setSpeed(targetKmh + 0.1f); break;
      case '-': setSpeed(targetKmh - 0.1f); break;
      case 'p': polling = !polling; Serial.printf("polling: %d\n", polling); break;
      case 'd': hexDump = !hexDump; Serial.printf("hexdump: %d\n", hexDump); break;
      default:
        if (ch >= '1' && ch <= '6') setSpeed((float)(ch - '0'));
        break;
    }
  }

  // ---- session integration @4Hz ----
  if (millis() - lastTick >= 250) {
    uint32_t dt = millis() - lastTick;
    lastTick = millis();
    if (beltRunning) {
      distanceM += actualKmh / 3.6 * dt / 1000.0;
      static uint32_t accMs = 0;
      accMs += dt;
      while (accMs >= 1000) { accMs -= 1000; elapsedS++; }
    }
  }

  // ---- detect the MCB stopping the belt on its own (no stop command):
  // actual speed pinned at 0 for >6s while we command RUN. Armed only after
  // the belt has actually moved, so startup ramp doesn't false-trigger. ----
  static bool beltMoved = false;
  static uint32_t stallSince = 0;
  if (!beltRunning) { beltMoved = false; stallSince = 0; }
  else if (actualKmh > 0.3f) { beltMoved = true; stallSince = 0; }
  else if (beltMoved && actualKmh < 0.05f) {
    if (stallSince == 0) stallSince = millis();
    else if (millis() - stallSince > 6000) {
      Serial.printf("!! MCB stopped the belt on its own (no stop cmd) t=%lus steps=%lu\n",
                    elapsedS, steps);
      beltRunning = false;
      notifyStatus(0x03);  // FTMS: stopped by safety — app shows it honestly
      stallSince = 0;
    }
  }

  // ---- safety: stop only on TRUE silence. Motor EMI corrupts up to ~50%
  // of replies while someone walks — corrupt bytes still prove the MCB is
  // alive, so they feed the watchdog. (v2's clean-reply watchdog caused
  // every "random stop while walking".) ----
  if (beltRunning && millis() - lastAnyReplyMs > 8000) {
    Serial.println("!! comms watchdog: MCB totally silent 8s — stopping");
    stopBelt();
    notifyStatus(0x03);  // machine-stopped, so the app pauses honestly
  }
  if (beltRunning && elapsedS > MAX_SESSION_S) {
    Serial.println("!! max session time — stopping");
    stopBelt();
  }

  // ---- Modbus poll rotation (console cadence) ----
  if (polling && millis() - lastPoll >= POLL_INTERVAL_MS) {
    lastPoll = millis();
    uint8_t resp[24];
    switch (pollPhase) {
      case 0:
        transact(0x03, 0x0101, 0x0001, resp, sizeof(resp));
        break;
      case 1:
        if (transact(0x03, 0xD10A, 0x0001, resp, sizeof(resp)) >= 5)
          actualKmh = ((resp[3] << 8) | resp[4]) / KMH_TO_VALUE;
        break;
      case 2:
        if (transact(0x03, 0x000F, 0x0001, resp, sizeof(resp)) >= 5)
          steps = (resp[3] << 8) | resp[4];
        break;
      case 3:
        transact(0x06, 0x000A,
                 beltRunning ? kmhToValue(targetKmh) : IDLE_VALUE,
                 resp, sizeof(resp));
        break;
    }
    pollPhase = (pollPhase + 1) & 3;
  }

  // ---- BLE notify @1Hz + serial status @5s ----
  if (millis() - lastNotify >= 1000) {
    lastNotify = millis();
    notifyTreadmillData();
    static uint8_t n = 0;
    if (++n >= 5) {
      n = 0;
      Serial.printf("[%s] %.2f km/h (target %.2f) dist %.0fm t %lus steps %lu | ok %lu to %lu crc %lu ble %d\n",
                    beltRunning ? "RUN" : "idle", actualKmh, targetKmh,
                    distanceM, elapsedS, steps,
                    okResponses, timeouts, crcErrors, bleConnected);
    }
  }
}
