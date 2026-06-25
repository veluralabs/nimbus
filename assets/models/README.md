# Face model slot

Drop a **MobileFaceNet** TFLite model here named exactly:

    mobilefacenet.tflite

Requirements:
- Input: 112 x 112 x 3, float, normalized (pixel - 127.5) / 128
- Output: 192-d embedding

Where to get one:
- Search "MobileFaceNet tflite 112 192" — several open MIT/Apache models exist
  (e.g. from the InsightFace / MobileFaceNet community repos).

Until this file is present, Nimbus still **detects and counts** faces via Cloud
Vision; it just can't **group** them into People. Once you add the model and
rebuild, the People tab fills in automatically (no code changes needed).
