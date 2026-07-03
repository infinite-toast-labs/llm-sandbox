Project: "True Noon" – A Solar Timing Utility

This prompt assumes it is being used inside the Android sandbox container, with the agent already running in the target app repository.

Before doing any app work, open and follow this skill file from the same prompt package:

```text
./skills/android-external-emulator/SKILL.md
```

Treat that file as required operating procedure for:

- container-only Android development
- connecting to the emulator running outside the container
- building, installing, launching, testing, and screenshot capture through the
  host ADB server bridge

If that skill file is not available, stop and say it is required.

## Working Requirements

- Work from the current repository directory.
- If the repository is empty or only partially initialized, bootstrap the Android project in place.
- Keep all build and test work inside the container.
- Do not run an emulator in the container.
- Use the external emulator bridge defined by the skill.
- Produce screenshot artifacts under `artifacts/android-e2e/`.
- Do not claim success unless the APK was installed from the container onto the external emulator and launched there.

## Objective

Build a single-screen Android application that calculates local Solar Noon based on a user's U.S. ZIP code and generates a workout and driving schedule.

## Core Functionality

Data retrieval:

- Fetch coordinates from a ZIP code using the Zippopotam API.
- Determine timezone and UTC offset using the Open-Meteo API.

Solar calculation:

- Implement the Equation of Time to calculate the exact moment of solar noon for the current date and location.

User inputs:

- ZIP code
- Trail run duration in minutes
- Drive time each way in minutes

Output schedule:

- Start driving: solar noon minus half the run minus drive time
- Start running: solar noon minus half the run
- Solar noon
- Finish running: solar noon plus half the run
- Drive back by: solar noon plus half the run plus drive time

Persistence:

- Include saved profiles using DataStore or Room for ZIP and duration presets such as `Central Park`.

## Required Delivery

- Working Android project in the current repository
- Container-side Gradle build
- APK installed from the container onto the external emulator over ADB
- App launched on the emulator
- At least one deterministic UI validation step
- Screenshots saved under `artifacts/android-e2e/`
