import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class SystemSpeechRateTest(unittest.TestCase):
    def test_android_integer_rates_preserve_uniform_slider_ticks(self):
        java_home = os.environ.get("JAVA_HOME")
        if not java_home:
            self.fail("JAVA_HOME must point to the declared JDK 17 for native rate tests")
        suffix = ".exe" if os.name == "nt" else ""
        java = Path(java_home) / "bin" / ("java" + suffix)
        javac = Path(java_home) / "bin" / ("javac" + suffix)
        self.assertTrue(java.is_file(), "Declared java executable is missing")
        self.assertTrue(javac.is_file(), "Declared javac executable is missing")
        root = Path(__file__).resolve().parents[1]
        source = root / "android/app/src/main/java/com/ddnovelreader/SystemSpeechRate.java"
        probe = root / "test/native/SystemSpeechRateProbe.java"
        with tempfile.TemporaryDirectory(prefix="ddnovel-rate-") as temporary:
            classes = Path(temporary) / "classes"
            classes.mkdir()
            built = subprocess.run(
                [str(javac), "--release", "17", "-d", str(classes), str(source), str(probe)],
                capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(built.returncode, 0, built.stderr)
            checked = subprocess.run(
                [str(java), "-Djava.io.tmpdir=" + temporary, "-cp", str(classes),
                 "com.ddnovelreader.SystemSpeechRateProbe"],
                capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
            self.assertIn("PASS: 126 UI ticks, 291 percent values", checked.stdout)


if __name__ == "__main__":
    unittest.main()
