# RobotRoom

An iPhone app with a toy robot in a 3D room. You talk to it, and it plans what to do,
walks around, picks things up and talks back. Everything runs on the phone.

- **3D room** (SceneKit): a robot, a red ball, a butter and a table, with physics and collisions.
  Drag to rotate the camera, use the joystick to walk the robot, and the Pick up / Drop button to carry things.
- **Speech to text**: NVIDIA Parakeet TDT 0.6B v3 through [FluidAudio](https://github.com/FluidInference/FluidAudio).
  Tap the mic, speak, tap again.
- **Understanding and planning**: Apple's on-device Foundation Models.
  The model decides whether a request is possible, chooses a goal and writes the steps
  ("pass the butter": walk to the butter, pick it up, walk to the player). The app checks the
  plan against a simple model of the room before the robot moves, and says honestly when it can't do something.
- **Text to speech**: Kokoro-82M (male voice `am_michael`) through FluidAudio, with a light robotic tone.
  The robot's mouth lights up as it talks.

## Things to say

"come here", "pass the butter", "put the ball on the table", "go to the left wall",
"walk back 2 meters", "drop it", "where is the ball?"

## Requirements

- Xcode 27 and an iPhone with Apple Intelligence on iOS 26 or later
  (the Foundation Models chat needs Apple Intelligence; the iOS 27 simulator also works).
- About 600 MB of models download on first launch (Parakeet ~470 MB, Kokoro ~125 MB).
- To run on a device, set your own signing team in the project (Signing & Capabilities).

## Known issues

- FluidAudio flags Kokoro as crash-prone on iOS 27 after long sessions
  ([FluidAudio#889](https://github.com/FluidInference/FluidAudio/issues/889)).
- In the simulator, Kokoro and Parakeet store their models in folders whose names differ
  only by case, which collide on a Mac's disk, so the voice falls back to Apple's speech synthesizer there.

## License

RobotRoom's code is under the [MIT License](LICENSE).

It uses third-party software and models under their own licenses, listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md):
[FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0),
[Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) by NVIDIA (CC BY 4.0) and
[Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) by hexgrad (Apache 2.0).
