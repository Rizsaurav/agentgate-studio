# Halcy Display Error Codes

All Halcy e-bikes (Halcy 40, Halcy 52 and Halcy 70 Cargo) use the same error code scheme on the handlebar display. Codes start with the letter E followed by two digits. The first digit tells you which system is affected: 1 for the display and controls, 2 for the battery and charger, 3 for the motor, and 4 for sensors.

These codes are not the same as the OB- error codes returned by the Orrinby Fleet API, and not the same as the blinking light patterns on the charger.

## Display and controls (E1x)

| Code | Meaning                                            | What to do                                                |
| ---- | -------------------------------------------------- | --------------------------------------------------------- |
| E10  | Communication error between display and controller | Switch off, check the display cable plug, switch on again |
| E11  | Button stuck                                       | Release all buttons and restart                           |
| E12  | Throttle signal out of range                       | Only fitted on export models; contact support             |
| E14  | Display firmware mismatch                          | Update firmware through the Orrinby Ride app              |

## Battery and charger (E2x)

| Code | Meaning                       | What to do                                                             |
| ---- | ----------------------------- | ---------------------------------------------------------------------- |
| E21  | Battery temperature too high  | Stop riding, let the battery cool for 30 minutes                       |
| E22  | Battery temperature too low   | Bring the battery indoors and warm it to above 0 °C                    |
| E23  | Unsupported charger connected | Use the charger that came with the bike                                |
| E24  | Battery cell imbalance        | Fully charge the battery and leave it on the charger for 2 extra hours |
| E25  | Battery not detected          | Remove and reinsert the battery, clean the contacts                    |

## Motor (E3x)

| Code | Meaning                 | What to do                                             |
| ---- | ----------------------- | ------------------------------------------------------ |
| E30  | Motor overheating       | Ride without assist for 10 minutes or rest             |
| E31  | Motor hall sensor fault | Book a service; do not ride with assist                |
| E33  | Motor over-current      | Restart; if it repeats, book a service                 |
| E35  | Motor locked            | Check that nothing is caught in the wheel or chainring |

## Sensors (E4x)

| Code | Meaning                  | What to do                                                          |
| ---- | ------------------------ | ------------------------------------------------------------------- |
| E40  | Speed sensor signal lost | Check that the wheel magnet is aligned with the sensor, within 5 mm |
| E41  | Torque sensor fault      | Halcy 52 and Halcy 70 Cargo only; book a service                    |
| E42  | Cadence sensor fault     | Halcy 40 only; check the sensor cable                               |
| E44  | Brake sensor stuck       | Check that both brake levers return fully                           |

## When to contact support

If an error appears more than three times in a week, export a diagnostic report from the Orrinby Ride app under **Bike > Diagnostics** and attach it to a support or warranty request. Errors E31 and E41 always require a workshop visit. Never open the battery or motor housing yourself, as this voids the warranty.

## Clearing an error

Most errors clear automatically once the cause is removed. To clear a stored error manually, hold the plus and minus buttons together for 5 seconds while the display is on. The last 20 errors are stored in the controller log and are visible to service technicians.
