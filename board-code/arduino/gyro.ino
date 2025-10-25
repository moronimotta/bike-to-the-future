#include <Wire.h>
#include <MPU6050_light.h>

MPU6050 mpu(Wire);

void setup() {
  Serial.begin(115200);
  Wire.begin();
  delay(2000);

  mpu.begin();
  mpu.calcGyroOffsets(); // keep MPU still while calibrating
  Serial.println("MPU6050 ready!");
}

void loop() {
  mpu.update(); // read sensor data

  float pitch = mpu.getAngleX(); // pitch in degrees
  float roll  = mpu.getAngleY(); // roll in degrees

  Serial.print("Pitch: "); Serial.print(pitch);
  Serial.print("  Roll: "); Serial.println(roll);

  // Detect downhill
  if (pitch > 10.0) {
    Serial.println("Going downhill!");
  }

  delay(200);
}