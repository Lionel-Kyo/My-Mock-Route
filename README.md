# Mock Location Simulator

A Flutter application for simulating GPS movement along custom routes on an interactive map. It supports configurable movement speed, GPS noise simulation, route persistence, GPX/JSON import and export, and optional Android Health Connect step synchronization.

## Features

- **Interactive Route Creation**
  - Tap on the map to create custom waypoints.
  - Build routes from multiple points.

- **Map Controls**
  - **Set Map North**: Reset the map orientation to north.
  - **Move to Current Location**: Center the map on the device's current location.

- **Real-Time GPS Simulation**
  - **Playback Controls**: Start, pause, resume, and stop simulations.
  - **Speed Control**: Configure simulation speed from 1 km/h to 800 km/h.
  - **GPS Noise Simulation**: Add configurable location accuracy and movement variations to make simulated movement less uniform.
  - **Background Simulation**: Continue route simulation using an Android foreground service.

- **Android Health Connect Integration**
  - Optionally convert simulated movement distance into step counts.
  - Enable or disable Health Connect step synchronization independently from GPS simulation.
  - Configure the **steps-per-meter** value.
  - Accumulate generated steps and periodically write them to Android Health Connect.
  - Health Connect permissions are required before step data can be written.

- **Route Records & Local Storage**
  - Save custom routes locally using `SharedPreferences`.
  - Reload saved routes onto the map.
  - Manage previously saved route records.

- **GPX & JSON Import/Export**
  - **Import** `.gpx` and `.json` route files.
  - **Export** saved routes for backup or use in other applications.
  - Long-press a saved route to export it.

## Health Connect Step Calculation

When Health Connect synchronization is enabled, simulated movement distance is converted into steps using the configured **steps-per-meter** value.

For example:

    10 meters × 1.3 steps/meter ≈ 13 steps

The default value is approximately `1.3 steps/meter`.

A higher value generates more steps for the same simulated distance, while a lower value generates fewer steps.

Generated steps are accumulated and periodically written to Health Connect rather than creating a new record for every GPS update.

## Android Permissions

The application may require Android permissions for:

- Fine/coarse location
- Background location
- Mock location functionality
- Foreground location service
- Health Connect step access

Health Connect step synchronization requires the user to grant the application's **Steps write permission** in Health Connect.

## Route Import and Export

The application supports importing and exporting routes using:

- GPX
- JSON

Routes can be saved locally and loaded again later.

## Important Notes

- GPS simulation behavior depends on the Android device and its location provider configuration.
- The GPS noise feature modifies simulated location characteristics; it does not guarantee that a particular application or service will accept or ignore simulated locations.
- Health Connect data is subject to Android Health Connect permissions and data-source behavior.
- Health Connect step synchronization is currently supported on Android.
- The application is intended for development, testing, and simulation purposes.

## Troubleshooting

### GPS simulation does not work

Make sure:

1. Location services are enabled.
2. The application has the required location permissions.
3. The application is configured as the device's mock location application.
4. The Android device allows mock locations.
5. The foreground service is allowed to run.

### Health Connect does not show the application

Make sure:

1. Health Connect is installed and available on the device.
2. The application declares the required Health Connect permissions.
3. The application has been reinstalled after changing the Health Connect manifest configuration.
4. Health Connect permissions have been granted to the application.
5. The Android device supports the required Health Connect APIs.

### Steps are higher or lower than expected

The number of generated steps depends on the simulated distance and the configured steps-per-meter value.

For example:

    1.0 steps/meter = approximately 1 step per meter
    1.3 steps/meter = approximately 1.3 steps per meter
    1.5 steps/meter = approximately 1.5 steps per meter

Higher values generate more steps for the same distance.

## Platform

Currently focused on **Android** with Flutter.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.