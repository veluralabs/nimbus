# TensorFlow Lite (used by tflite_flutter for on-device face embeddings).
# The optional GPU delegate classes are referenced but not always present;
# keep what exists and silence warnings for the rest.
-keep class org.tensorflow.** { *; }
-dontwarn org.tensorflow.lite.gpu.**
-dontwarn org.tensorflow.**
