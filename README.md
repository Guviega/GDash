# 🏁 GDash

### Your real-time OBD-II dashboard

![Flutter](https://img.shields.io/badge/Flutter-Android-02569B?logo=flutter&logoColor=white)
![OBD-II](https://img.shields.io/badge/OBD--II-SAE%20J1979-16a085)
![Bluetooth](https://img.shields.io/badge/Bluetooth-BLE%20%2B%20SPP-3569e8?logo=bluetooth&logoColor=white)
![Status](https://img.shields.io/badge/status-in%20development-f39c12)

**GDash** connects an ELM327 adapter to your Android phone and turns OBD-II responses into easy-to-read information while the engine is running.

> [!TIP]
> The protocol shown in Car Scanner—for example, **ISO 15765-4 CAN, 11-bit ID, 500 kbaud**—describes communication between the adapter and the car's ECU. Bluetooth is the separate connection between the adapter and your phone.

## ✨ Dashboard readings

| Indicator | What it shows | Source |
| --- | --- | --- |
| 🔄 **RPM** | Engine speed | PID `01 0C` |
| 🚦 **Shift lights** | Progressive lights at 2,000, 3,000, 4,000, 5,000, and 6,000 rpm | Engine RPM |
| 🌡️ **Temperature** | Engine coolant temperature | PID `01 05` |
| ⛽ **Fuel economy** | Estimated km/L | Airflow + vehicle speed |
| ⚡ **Ignition timing** | Spark advance in degrees | PID `01 0E` |
| 🛢️ **Fuel level** | Tank level percentage | PID `01 2F` |
| 🌀 **Turbo pressure** | Relative pressure in bar | MAP (`01 0B`) − barometric pressure (`01 33`) |
| 🦶 **Accelerator** | Pedal percentage; throttle position as a fallback | PID `01 49`; fallback `01 11` |
| 🏎️ **Speed** | Vehicle speed in km/h | PID `01 0D` |

### 🚥 Shift lights

The lights turn on progressively as engine speed rises: **green at 2,000 rpm**, two **yellow** lights at 3,000 and 4,000 rpm, **orange** at 5,000 rpm, and **red** at 6,000 rpm. At 6,000 rpm, **all five lights flash** as a shift warning.

## 📡 Connecting to the ELM327

GDash scans for nearby adapters using:

- **Bluetooth Classic (SPP/RFCOMM):** Android may require pairing to open the serial connection.
- **Bluetooth Low Energy (BLE):** the adapter can be discovered and connected to directly in the app, without appearing in Android's pairing list.

After you select an adapter, GDash initializes the ELM327 with `AT` commands and polls OBD-II PIDs in sequence. It converts hexadecimal responses into the units shown on the dashboard. If the scanner disconnects, the app shows the disconnected state.

### How to connect

1. Plug the ELM327 into the car's OBD-II port and turn on the ignition.
2. Turn on Bluetooth and allow GDash to access nearby devices.
3. Open the app and tap **Connect**.
4. Select the adapter from the nearby devices list. If you use Bluetooth Classic, allow pairing if Android asks.
5. Wait for the **Connected · reading vehicle data** status.

## 🧮 How the estimates work

- **Fuel economy in km/L:** estimated from airflow (MAF) and vehicle speed, assuming gasoline and the stoichiometric air-fuel ratio. This is an approximation; it may differ from the vehicle's onboard computer, especially in flex-fuel or diesel vehicles, or when MAF data is unavailable.
- **Turbo pressure:** calculated as absolute manifold pressure minus barometric pressure. It can be negative when the intake manifold is under vacuum, and requires the vehicle to provide both PIDs.
- **Accelerator:** GDash first uses the accelerator pedal position PID. If the vehicle does not provide it, the app uses throttle position, which may not match the pedal's actual travel percentage.

## 🧩 Compatibility and limitations

- The project currently targets **Android**. Generic ELM327 connections over SPP/BLE are not configured for iOS yet.
- Compatibility depends on the adapter. ELM327 clones can vary in BLE services, supported commands, and response speed.
- Each vehicle provides different PIDs. `--` means the data has not arrived yet or is not available from the ECU.
- Fuel level and ignition timing depend on vehicle support and are not guaranteed for every model.
- The dashboard is read-only. GDash does not clear trouble codes or change ECU parameters.

## 🛠️ Development

### Requirements

- Flutter installed
- Android SDK configured
- An Android device for Bluetooth testing
- A compatible ELM327 adapter

### Run on a phone

```bash
flutter pub get
flutter run
```

### Build a debug APK

```bash
flutter build apk --debug
```

The generated file is located at `build/app/outputs/flutter-apk/app-debug.apk`.

## 🧱 Technologies

- Develop using ChatGPT Work
- [Flutter](https://flutter.dev/) and Dart
- [`flutter_bluetooth_serial_plus`](https://pub.dev/packages/flutter_bluetooth_serial_plus) — Bluetooth Classic serial communication
- [`flutter_blue_plus`](https://pub.dev/packages/flutter_blue_plus) — BLE discovery and connections
- SAE J1979 / OBD-II — standardized requests and PIDs

---

<p align="center"><b>GDash</b> · car data, right on your dashboard 📊🚘</p>
