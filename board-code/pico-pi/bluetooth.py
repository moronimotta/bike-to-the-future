import bluetooth
import time
import ubinascii
from micropython import const
from machine import Pin

# --- Minimal advertising payload helpers (inlined) ---
_ADV_TYPE_FLAGS = const(0x01)
_ADV_TYPE_NAME = const(0x09)
_ADV_TYPE_UUID16_COMPLETE = const(0x03)
_ADV_TYPE_UUID128_COMPLETE = const(0x07)


def _append(payload, adv_type, value):
    payload += bytes((len(value) + 1, adv_type)) + value
    return payload


def advertising_payload(name=None, services=None, limited_disc=False, br_edr=False):
    payload = bytearray()
    flags = (0x01 if limited_disc else 0x02) | (0x18 if br_edr else 0x04)
    payload = _append(payload, _ADV_TYPE_FLAGS, bytes((flags,)))
    if name:
        if isinstance(name, str):
            name = name.encode()
        payload = _append(payload, _ADV_TYPE_NAME, name)
    if services:
        for uuid in services:
            b = bytes(uuid)
            if len(b) == 2:
                payload = _append(payload, _ADV_TYPE_UUID16_COMPLETE, b)
            elif len(b) == 16:
                payload = _append(payload, _ADV_TYPE_UUID128_COMPLETE, b)
    return payload


# --- BLE constants and UUIDs ---
_IRQ_CENTRAL_CONNECT = const(1)
_IRQ_CENTRAL_DISCONNECT = const(2)
_IRQ_GATTS_WRITE = const(3)

_FLAG_READ = const(0x0002)
_FLAG_WRITE = const(0x0008)
_FLAG_NOTIFY = const(0x0010)

# Nordic UART Service (NUS)
_UART_UUID = bluetooth.UUID("6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
_UART_TX = (bluetooth.UUID("6E400003-B5A3-F393-E0A9-E50E24DCCA9E"), _FLAG_NOTIFY)
_UART_RX = (bluetooth.UUID("6E400002-B5A3-F393-E0A9-E50E24DCCA9E"), _FLAG_WRITE)
_UART_SERVICE = (_UART_UUID, (_UART_TX, _UART_RX))


class BLECoordinate:
    """BLE peripheral that advertises as 'Pico <MAC>' and sends a mock GPS coordinate (lat,lon)."""

    def __init__(self, ble):
        self._ble = ble
        self._ble.active(True)
        self._ble.irq(self._irq)

        # Register GATT service
        ((self._tx_handle, self._rx_handle),) = self._ble.gatts_register_services((_UART_SERVICE,))

        self._connections = set()
        self._led = Pin("LED", Pin.OUT)

        # Device name: 'Pico-Bike <MAC>'
        mac = ubinascii.hexlify(self._ble.config("mac")[1], ":").decode().upper()
        self._name = "Pico-Bike %s" % mac
        print("BLE name:", self._name)

        # Start advertising (include service UUID)
        adv = advertising_payload(name=self._name, services=[_UART_UUID])
        self._start_advertising(adv)

    # --- BLE event handling ---
    def _irq(self, event, data):
        if event == _IRQ_CENTRAL_CONNECT:
            conn_handle, _, _ = data
            self._connections.add(conn_handle)
            self._led.value(1)
            print("Central connected:", conn_handle)
        elif event == _IRQ_CENTRAL_DISCONNECT:
            conn_handle, _, _ = data
            self._connections.discard(conn_handle)
            self._led.value(0)
            print("Central disconnected:", conn_handle)
            # Restart advertising
            adv = advertising_payload(name=self._name, services=[_UART_UUID])
            self._start_advertising(adv)
        elif event == _IRQ_GATTS_WRITE:
            conn_handle, value_handle = data
            if value_handle == self._rx_handle:
                incoming = self._ble.gatts_read(self._rx_handle)
                print("RX from phone:", incoming)

    # --- Public API ---
    def send_coordinate(self, lat, lon):
        msg = ("{:.6f},{:.6f}".format(lat, lon)).encode()
        self._ble.gatts_write(self._tx_handle, msg)
        for conn in tuple(self._connections):
            try:
                self._ble.gatts_notify(conn, self._tx_handle, msg)
            except Exception as e:
                print("Notify failed:", e)

    # --- Advertising ---
    def _start_advertising(self, adv_data, interval_us=500_000):
        self._ble.gap_advertise(interval_us, adv_data=adv_data)
        print("Advertising as:", self._name)


def demo():
    # Create BLE peripheral named 'Pico <MAC>'
    ble = bluetooth.BLE()
    device = BLECoordinate(ble)

    # Mock coordinate (example: San Francisco)
    mock_lat = 37.774900
    mock_lon = -122.419400

    while True:
        device.send_coordinate(mock_lat, mock_lon)
        time.sleep(2)


if __name__ == "__main__":
    demo()
