const int ldrPin = A0;      // LDR input
const int ledTransistor = 7; // Base resistor connected here
const int threshold = 100;   // Adjust this depending on your LDR readings

void setup() {
  pinMode(ledTransistor, OUTPUT);
  Serial.begin(9600);
}

void loop() {
  int lightValue = analogRead(ldrPin);
  Serial.println(lightValue);

  if (lightValue < threshold) {
    digitalWrite(ledTransistor, HIGH);  // turn LEDs on when dark
  } else {
    digitalWrite(ledTransistor, LOW);   // turn off when bright
  }
  delay(200);
}