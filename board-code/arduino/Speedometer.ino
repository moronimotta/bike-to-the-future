#include <Adafruit_GFX.h>
#include <Adafruit_ST7735.h>
#include <SPI.h>

// TFT pins
#define TFT_CS     10
#define TFT_DC     8
#define TFT_RST    9

Adafruit_ST7735 tft = Adafruit_ST7735(TFT_CS, TFT_DC, TFT_RST);

// Reed switch pin
const int reedPin = 2;

// Wheel measurement
float wheelCircumference = 2.20; // meters (27x1 7/8 tire)

// Speed and distance tracking
volatile unsigned long lastTime = 0;
volatile unsigned long interval = 0;
volatile bool pulseDetected = false;

float speed = 0.0;       // MPH
float maxSpeed = 0.0;    // MPH
float distance = 0.0;    // miles

// Conversion constants
const float MPS_TO_MPH = 2.23694;
const float METERS_TO_MILES = 0.000621371;

// Max speed threshold for sanity check
const float MAX_SPEED_THRESHOLD = 40.0; // mph

void setup() {
  Serial.begin(9600);
  pinMode(reedPin, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(reedPin), reedTriggered, FALLING);

  // Initialize TFT
  tft.initR(INITR_BLACKTAB);
  tft.setRotation(1);
  tft.fillScreen(ST77XX_BLACK);

  // Initial screen
  tft.setTextColor(ST77XX_WHITE);
  tft.setTextSize(2);
  tft.setCursor(10, 10);
  tft.println("Bike Speedometer");
  delay(1500);
  tft.fillScreen(ST77XX_BLACK);
}

void loop() {
  // Update display only when a new pulse is detected
  if (pulseDetected) {
    pulseDetected = false;

    // Display speed, max, and distance
    displayData();
  }
}

void reedTriggered() {
  unsigned long currentTime = millis();
  interval = currentTime - lastTime;
  lastTime = currentTime;

  // Ignore extremely fast triggers (debounce)
  if (interval > 50) {
    pulseDetected = true;

    // Calculate speed in MPH
    float speedMps = wheelCircumference / (interval / 1000.0);
    speed = speedMps * MPS_TO_MPH;

    // Cap speed display for sanity (optional)
    if (speed > 60.0) speed = 60.0;

    // Only update maxSpeed if under threshold
    if (speed < MAX_SPEED_THRESHOLD && speed > maxSpeed) {
      maxSpeed = speed;
    }

    // Update distance
    distance += wheelCircumference * METERS_TO_MILES;
  }
}

void displayData() {
  tft.fillScreen(ST77XX_BLACK);

  // Current speed
  tft.setTextColor(ST77XX_GREEN);
  tft.setTextSize(3);
  tft.setCursor(10, 10);
  tft.print(speed, 1);
  tft.println(" MPH");

  // Max speed
  tft.setTextColor(ST77XX_YELLOW);
  tft.setTextSize(2);
  tft.setCursor(10, 55);
  tft.print("Max: ");
  tft.print(maxSpeed, 1);
  tft.println(" MPH");

  // Distance
  tft.setTextColor(ST77XX_CYAN);
  tft.setTextSize(2);
  tft.setCursor(10, 80);
  tft.print("Dist: ");
  tft.print(distance, 2);
  tft.println(" mi");
}
