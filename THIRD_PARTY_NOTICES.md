# Third-party notices

RobotRoom's own source code is under the MIT License (see `LICENSE`). It depends on the
following third-party software and models, which keep their own licenses. None of them is
copied into this repository: the Swift package is fetched by Xcode, and the models are
downloaded by the app on first launch.

## Software

### FluidAudio
- Used for: running Parakeet (speech to text) and Kokoro (text to speech) on device with Core ML.
- Source: https://github.com/FluidInference/FluidAudio (Swift Package Manager, version 0.17.x)
- License: Apache License 2.0
- FluidAudio bundles further third-party components (for example `text-processing-rs`,
  fastcluster and the Kokoro Core ML conversions). Their licenses and notices are in the
  package's `ThirdPartyLicenses` folder and `LICENSE` file.

### Apple frameworks
- SwiftUI, SceneKit, AVFoundation and Foundation Models are part of Apple's SDKs and are
  used under the Apple Developer Program License Agreement.
- Apps using the Foundation Models framework must follow Apple's acceptable use
  requirements for it: https://developer.apple.com/apple-intelligence/acceptable-use-requirements-for-the-foundation-models-framework

## Models

### Parakeet TDT 0.6B v3 (speech to text)
- Author: NVIDIA. Original model: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- Core ML conversion used by the app: https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
- License: Creative Commons Attribution 4.0 International (CC BY 4.0),
  https://creativecommons.org/licenses/by/4.0/
- Attribution: "parakeet-tdt-0.6b-v3" by NVIDIA, licensed under CC BY 4.0, converted to
  Core ML by FluidInference. Used unmodified.

### Kokoro-82M (text to speech)
- Author: hexgrad. Original model: https://huggingface.co/hexgrad/Kokoro-82M
- Core ML conversion used by the app: https://huggingface.co/FluidInference/kokoro-82m-coreml
  (derived from https://github.com/laishere/kokoro-coreml)
- License: Apache License 2.0
- Voice used: `am_michael`. The app adds a light robotic effect to the generated audio.
