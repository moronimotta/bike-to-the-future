# Bike Navigation App

A Flutter-based mobile application that provides cycling-optimized navigation with downhill detection and Bluetooth connectivity to a Raspberry Pi Pico display device.

## Features

- **Bluetooth Integration**: Connects to a Raspberry Pi Pico device via BLE for displaying route information
- **Smart Navigation**: Uses Google Maps API to find bicycle-friendly routes
- **Elevation Awareness**: Shows downhill segments and elevation changes along the route
- **Real-time Location**: Uses device GPS for accurate current position tracking
- **Turn-by-turn Navigation**: Provides detailed navigation instructions

## Technical Stack

- **Frontend**: Flutter
- **Location Services**: Geolocator package
- **Bluetooth**: Flutter Blue Plus for BLE communication
- **Navigation**: Google Maps Routes API
- **Hardware**: Raspberry Pi Pico W for route display

## Getting Started

### Prerequisites
- Flutter SDK
- Android Studio or Xcode
- Physical Android/iOS device (Bluetooth LE testing requires real hardware)
- Google Maps API key

### Setup

1. Clone the repository:
```bash
git clone https://github.com/moronimotta/untitled-bike-project.git
```

2. Install dependencies:
```bash
cd mobile-app/bike_app
flutter pub get
```

3. Run the app:
```bash
flutter run
```

### Configuration

The app requires the following permissions:
- Location access
- Bluetooth scanning and connection
- Internet access

## API Integration

The app communicates with a custom Google Maps Route API service that provides:
- Cycling-optimized routes
- Elevation data
- Downhill segment detection
- Turn-by-turn navigation points

## Hardware Connection

Connects to a Raspberry Pi Pico W device via Bluetooth LE using:
- Nordic UART Service (NUS)
- Device name format: "Pico-Bike {MAC}"
- Sends route information via BLE notifications

## Contributing

1. Fork the repository
2. Create your feature branch
3. Commit your changes
4. Push to the branch
5. Create a new Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.