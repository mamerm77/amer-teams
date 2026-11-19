# Background blur and low light

Plugin: `app/plugins/amer_background`. The camera frames are changed on the sender's device, **before** they are encoded and end-to-end encrypted, so no server ever sees the unblurred video.

| Platform | How |
|---|---|
| Android | flutter_webrtc `LocalVideoTrack.addProcessor`; ML Kit selfie segmentation (stream mode) gives a person mask; background is blurred by down/up-scaling and blended with the mask; low light is a colour-matrix lift |
| iOS 15+ | `LocalVideoTrack addProcessing:`; Apple Vision `VNGeneratePersonSegmentationRequest` mask; Core Image Gaussian blur and `CIBlendWithMask`; low light via `CIColorControls` |
| iOS 13–14 | Low light only (no Vision person segmentation) |
| Desktop / web | Not available; the buttons are hidden |

In a call: **Blur background** and **Low light** buttons appear next to the camera button when video is on. Any error in an effect returns the original frame, so video is never dropped because of it.

## Open gaps
- Built and compiled in CI, but **not yet tested on a real camera**: CI has no device camera. Frame rate on low-end Android is unknown; the Android path converts YUV↔RGB on the CPU and may need a GPU (RenderScript replacement / GLES) path.
- No virtual backgrounds (image replacement) yet; the mask is there, the picker is not.
- Noise suppression, echo cancellation and gain control were already on for every call.
