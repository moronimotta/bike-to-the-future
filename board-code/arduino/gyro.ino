#include <Wire.h>
#include <MPU6050_light.h>
#include <Servo.h>

MPU6050 mpu(Wire);
Servo brakeServo;

const int servoPin = 9;

// Servo range for brake: 0 = released, 90 = full brake
const int minServoAngle = 0;
const int maxServoAngle = 90;

// Max pitch to apply full brake
const float maxPitch = 45.0;

void setup() {
  Serial.begin(9600);
  Wire.begin();

  brakeServo.attach(servoPin);
  brakeServo.write(minServoAngle); // start released

  if (mpu.begin() != 0) {
    Serial.println("MPU6050 init failed!");
    while(1);
  }
  Serial.println("MPU6050 ready!");
}

void loop() {
  mpu.update();

  float ax = mpu.getAccX();
  float ay = mpu.getAccY();
  float az = mpu.getAccZ();

  // Compute pitch in degrees
  float pitch = atan2(ax, sqrt(ay*ay + az*az)) * 180 / PI;

  // Map pitch to servo angle
  int servoAngle;
  if (pitch <= 0) {
    servoAngle = minServoAngle; // uphill or level → release brake
  } else {
    servoAngle = map(constrain(pitch, 0, maxPitch), 0, maxPitch, minServoAngle, maxServoAngle);
  }

  brakeServo.write(servoAngle);

  // Debug output
  Serial.print("Pitch: "); Serial.print(pitch,1);
  Serial.print("°  Servo Angle: "); Serial.println(servoAngle);

  delay(50);
}