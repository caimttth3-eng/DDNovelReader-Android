package com.ddnovelreader;

/** Encodes a decimal rate for Android's integer-percent TTS request. */
public final class SystemSpeechRate {
    private SystemSpeechRate() {}

    public static float toPlatformRate(double requested) {
        if (!Double.isFinite(requested)) {
            throw new IllegalArgumentException("Speech rate must be finite");
        }
        double bounded = Math.max(0.1, Math.min(3.0, requested));
        int percent = (int) Math.round(bounded * 100.0);
        float encoded = percent / 100.0f;
        // TextToSpeech casts (floatRate * 100) to int. For example, 2.1f
        // otherwise produces 209 instead of the requested 210. One ULP is
        // sufficient to retain the intended percent without changing a tick.
        if ((int) (encoded * 100.0f) < percent) {
            encoded = Math.nextUp(encoded);
        }
        return encoded;
    }
}
