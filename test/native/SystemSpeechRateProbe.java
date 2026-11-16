package com.ddnovelreader;

public final class SystemSpeechRateProbe {
    private static int platformPercent(double rate) {
        return (int) (SystemSpeechRate.toPlatformRate(rate) * 100.0f);
    }

    private static void expectPercent(double rate, int expected) {
        int actual = platformPercent(rate);
        if (actual != expected) {
            throw new AssertionError(rate + " -> " + actual + ", expected " + expected);
        }
    }

    public static void main(String[] args) {
        int previous = -1;
        for (int percent = 50; percent <= 300; percent += 2) {
            double rate = percent / 100.0;
            expectPercent(rate, percent);
            if (previous >= 0 && platformPercent(rate) - previous != 2) {
                throw new AssertionError("Nonuniform UI step at " + rate);
            }
            previous = platformPercent(rate);
        }
        for (int percent = 10; percent <= 300; percent++) {
            expectPercent(percent / 100.0, percent);
        }
        expectPercent(1.4, 140);
        expectPercent(1.5, 150);
        expectPercent(2.1, 210);
        expectPercent(-1.0, 10);
        expectPercent(10.0, 300);
        for (double invalid : new double[] {Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY}) {
            try {
                SystemSpeechRate.toPlatformRate(invalid);
                throw new AssertionError("Accepted non-finite rate");
            } catch (IllegalArgumentException expected) {
                // No invalid rate may reach the engine.
            }
        }
        System.out.println("PASS: 126 UI ticks, 291 percent values, clamps and invalid inputs");
    }
}
