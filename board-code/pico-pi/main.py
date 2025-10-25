import bluetooth
import time
import ubinascii
import ujson
import math
from micropython import const
from machine import Pin, UART

# =====================================
# SERIAL OUTPUT ONLY (no TFT display)
# =====================================
print("Pico Bike Navigator (Serial mode)")

# ============================================================
# BLE CONSTANTS
# ============================================================
_IRQ_CENTRAL_CONNECT = const(1)
_IRQ_CENTRAL_DISCONNECT = const(2)
_IRQ_GATTS_WRITE = const(3)

_FLAG_READ = const(0x0002)
_FLAG_WRITE = const(0x0008)
_FLAG_NOTIFY = const(0x0010)

_UART_UUID = bluetooth.UUID("6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
_UART_TX = (bluetooth.UUID("6E400003-B5A3-F393-E0A9-E50E24DCCA9E"), _FLAG_NOTIFY)
_UART_RX = (bluetooth.UUID("6E400002-B5A3-F393-E0A9-E50E24DCCA9E"), _FLAG_WRITE)
_UART_SERVICE = (_UART_UUID, (_UART_TX, _UART_RX))

# ============================================================
# NAVIGATION HELPERS (no longer needed; phone does the work)
# ============================================================
# (removed haversine_distance, extract_street_name, get_turn_direction,
#  bearing_degrees, signed_angle_diff, classify_turn)

# ============================================================
# BLE ADVERTISING PAYLOAD HELPER
# ============================================================
def advertising_payload(name=None, services=None, limited_disc=False, br_edr=False):
    payload = bytearray()
    flags = (0x01 if limited_disc else 0x02) | (0x18 if br_edr else 0x04)
    payload += bytes([2, 0x01, flags])
    if name:
        payload += bytes([len(name) + 1, 0x09]) + name.encode()
    if services:
        for uuid in services:
            b = bytes(uuid)
            if len(b) == 2:
                payload += bytes([3, 0x03]) + b
            elif len(b) == 16:
                payload += bytes([17, 0x07]) + b
    return payload

# ============================================================
# BLE DEVICE CLASS
# ============================================================
class BLECoordinate:
    def __init__(self, ble):
        self._ble = ble
        self._ble.active(True)
        self._ble.irq(self._irq)

        ((self._tx_handle, self._rx_handle),) = self._ble.gatts_register_services((_UART_SERVICE,))
        self._connections = set()
        self._led = Pin("LED", Pin.OUT)

        mac = ubinascii.hexlify(self._ble.config("mac")[1], ":").decode().upper()
        self._name = "Pico {}".format(mac)
        print("BLE name:", self._name)

        adv = advertising_payload(name=self._name, services=[_UART_UUID])
        self._start_advertising(adv)

    def _irq(self, event, data):
        if event == _IRQ_CENTRAL_CONNECT:
            conn_handle, _, _ = data
            self._connections.add(conn_handle)
            self._led.value(1)
            print("Connected:", conn_handle)

        elif event == _IRQ_CENTRAL_DISCONNECT:
            conn_handle, _, _ = data
            self._connections.discard(conn_handle)
            self._led.value(0)
            print("Disconnected:", conn_handle)
            adv = advertising_payload(name=self._name, services=[_UART_UUID])
            self._start_advertising(adv)

        elif event == _IRQ_GATTS_WRITE:
            conn_handle, value_handle = data
            if value_handle == self._rx_handle:
                incoming = self._ble.gatts_read(self._rx_handle)
                # Fast path: NAV commands from phone like b"NAV:street|dist|turn|next\n"
                try:
                    if incoming.startswith(b'NAV:'):
                        try:
                            txt = incoming.decode().strip()
                            # Parse: NAV:currentStreet|dist|turn|nextStreet
                            _, rest = txt.split(':', 1)
                            parts = rest.split('|')
                            if len(parts) == 4:
                                current_street, dist, turn, next_street = parts
                                print("ON {} | IN {} {} onto {}".format(current_street, dist, turn, next_street))
                            else:
                                print("NAV:", txt)
                        except Exception as pe:
                            print("NAV parse error:", pe)
                        return
                except Exception:
                    pass
                # Otherwise just print raw incoming
                print("Received:", incoming)

    def send_coordinate(self, lat, lon):
        """Send current GPS coordinate back to phone"""
        msg = "{:.6f},{:.6f}".format(lat, lon).encode()
        self._ble.gatts_write(self._tx_handle, msg)
        for conn in tuple(self._connections):
            try:
                self._ble.gatts_notify(conn, self._tx_handle, msg)
            except Exception as e:
                print("Notify failed:", e)

    def _start_advertising(self, adv_data, interval_us=500_000):
        self._ble.gap_advertise(interval_us, adv_data=adv_data)
        print("Advertising as:", self._name)

# ============================================================
# GPS PARSER (NEO-7M)
# ============================================================
class GPSReader:
    def __init__(self, tx_pin=4, rx_pin=5, baudrate=9600):
        self.uart = UART(1, baudrate=baudrate, tx=Pin(tx_pin), rx=Pin(rx_pin))
        self.lat = None
        self.lon = None

    def _convert_to_decimal(self, raw, direction):
        if len(raw) < 4:
            return None
        degrees = float(raw[:2])
        minutes = float(raw[2:])
        coord = degrees + (minutes / 60)
        if direction in ['S', 'W']:
            coord = -coord
        return coord

    def read(self):
        if self.uart.any():
            line = self.uart.readline()
            if not line:
                return None
            try:
                decoded = line.decode().strip()
                if decoded.startswith('$GPGGA'):
                    parts = decoded.split(',')
                    if len(parts) > 5:
                        lat_raw = parts[2]
                        lat_dir = parts[3]
                        lon_raw = parts[4]
                        lon_dir = parts[5]
                        lat = self._convert_to_decimal(lat_raw, lat_dir)
                        lon = self._convert_to_decimal(lon_raw, lon_dir)
                        if lat and lon:
                            self.lat, self.lon = lat, lon
                            return lat, lon
            except Exception as e:
                print("GPS error:", e)
        return None

# ============================================================
# MAIN DEMO
# ============================================================
def demo():
    # Initialize BLE and GPS
    ble = bluetooth.BLE()
    device = BLECoordinate(ble)
    gps = GPSReader()

    print("Pico Bike Navigator Ready!")
    print("Waiting for Flutter app connection...")

    last_gps_time = 0
    mock_lat, mock_lng = 37.774900, -122.419400  # Default coordinates

    while True:
        try:
            # Try to read GPS
            coords = gps.read()
            if coords:
                mock_lat, mock_lng = coords
                print("GPS: {:.6f}, {:.6f}".format(mock_lat, mock_lng))
            
            # Send current position every 5 seconds
            if time.ticks_diff(time.ticks_ms(), last_gps_time) > 5000:
                if device._connections:  # Only send if connected
                    device.send_coordinate(mock_lat, mock_lng)
                last_gps_time = time.ticks_ms()

            time.sleep(0.1)
            
        except Exception as e:
            print("Main loop error:", e)
            time.sleep(1)

if __name__ == "__main__":
    demo()
