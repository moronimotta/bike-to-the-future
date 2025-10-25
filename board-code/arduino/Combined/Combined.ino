const int ldrPin = A0;      // LDR input
const int ledTransistor = 7; // Base resistor connected here
const int threshold = 100;   // Adjust this depending on your LDR readings

#include <LiquidCrystal_I2C.h>

// LC pins
#define LC_SDA 11
#define LC_SCL 13

LiquidCrystal_I2C lcd(0x27, 16, 2);

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

  lcd.init();
  lcd.backlight();
  lcd.setCursor(0, 0);
  lcd.print("Bikes");
  delay(1000);

  pinMode(ledTransistor, OUTPUT);
}

void loop() {
  // Update display only when a new pulse is detected
  if (pulseDetected) {
    Serial.println("Reed fired!");
    pulseDetected = false;

    // Display speed, max, and distance
    displayData();
  }
    int lightValue = analogRead(ldrPin);
  Serial.println(lightValue);

  if (lightValue < threshold) {
    digitalWrite(ledTransistor, HIGH);  // turn LEDs on when dark
  } else {
    digitalWrite(ledTransistor, LOW);   // turn off when bright
  }
  delay(200);
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
  lcd.clear();
  
  // Current speed
  lcd.setCursor(0, 0);
  lcd.print("Speed: ");
  lcd.print(speed);
  lcd.print(" MPH");

  // Distance
  lcd.setCursor(0, 1);
  lcd.print("Dist: ");
  lcd.print(distance);
  lcd.print(" mi");
}
