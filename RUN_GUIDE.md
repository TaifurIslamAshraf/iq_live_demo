# IQ Live Demo - Run Guide (Physical Device)

To run this application on a physical device connected via USB, follow these steps:

## Prerequisites

1.  **Development Machine & Mobile Device** must be connected to the **same Wi-Fi network**.
2.  **USB Debugging** must be enabled on your mobile device.
3.  **Backend Services** must be running on your development machine:
    - **LiveKit Server**: Port 7880
    - **Backend API**: Port 8000 (Ensure it's listening on `0.0.0.0`)
    - **Redis**: Port 6379

## Configuration

The application is currently configured to connect to your machine at:
- **Local IP**: `192.168.0.105`

If your machine's IP changes, update the `SocialIqLiveSdk.initialize` call in `lib/main.dart`:

```dart
await SocialIqLiveSdk.initialize(
  serverUrl:  'ws://<YOUR_LOCAL_IP>:7880',
  socketUrl:  'http://<YOUR_LOCAL_IP>:8000',
  apiBaseUrl: 'http://<YOUR_LOCAL_IP>:8000',
);
```

To find your IP:
- **Linux/Mac**: `hostname -I` or `ifconfig`
- **Windows**: `ipconfig`

## How to Run

1.  Connect your device via USB.
2.  Open a terminal in the `iq_live_demo` directory.
3.  Check if your device is detected:
    ```bash
    flutter devices
    ```
4.  Run the application:
    ```bash
    flutter run
    ```
    If multiple devices are connected, use:
    ```bash
    flutter run -d <DEVICE_ID>
    ```

## Troubleshooting

- **Connection Refused**: Ensure your computer's firewall is not blocking ports 7880 and 8000.
- **Can't Ping**: Ensure both devices are on the same subnet and "Client Isolation" is disabled on the router.
- **LiveKit Issues**: Check if the LiveKit Docker container is running and healthy.
