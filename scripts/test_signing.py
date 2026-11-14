import base64
import hashlib
import json
import os
from pathlib import Path
import tempfile
import subprocess
import contextlib
import io
import unittest
from unittest.mock import patch

import prepare_signing as prepare
import sign_apk


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.addCleanup(self.directory.cleanup)
        self.secret = {"version": 1, "storeType": "PKCS12", "keystoreBase64": base64.b64encode(b"test-only-key").decode(),
                       "keyAlias": "ddnovelreader", "storePassword": "test-store-password", "keyPassword": "test-key-password"}
        self.expected = hashlib.sha256(b"test-certificate").hexdigest()

    def test_secret_schema_and_strict_base64(self):
        self.assertEqual(prepare.read_secret(json.dumps(self.secret))[1], b"test-only-key")
        for change in ({"version": 2}, {"storeType": "JKS"}, {"keystoreBase64": "%%%"},
                       {"keyAlias": "bad&alias"}, {"keyPassword": ""}):
            with self.subTest(change=change), self.assertRaises(prepare.SigningError):
                prepare.read_secret(json.dumps(self.secret | change))

    def test_invalid_json_does_not_echo_secret(self):
        with self.assertRaises(prepare.SigningError) as caught:
            prepare.read_secret('not-json-test-store-password')
        self.assertNotIn(self.secret["storePassword"], str(caught.exception))

    def test_public_fingerprint_validation(self):
        path = self.root / "certificate.sha256"
        path.write_text(":".join(self.expected[i:i + 2] for i in range(0, 64, 2)).upper() + "\n")
        self.assertEqual(prepare.fingerprint(path), self.expected)
        path.write_text("bad")
        with self.assertRaises(prepare.SigningError):
            prepare.fingerprint(path)

    def test_restore_checks_pin_before_writing_properties(self):
        with patch.object(prepare, "check_keystore") as check:
            properties = prepare.restore(json.dumps(self.secret), self.root, self.expected)
        check.assert_called_once()
        self.assertIn("storeType=PKCS12", properties.read_text())
        self.assertEqual((self.root / "keystore.p12").read_bytes(), b"test-only-key")
        prepare.cleanup(self.root)
        self.assertFalse(properties.exists())

    def test_wrong_certificate_removes_restored_private_files(self):
        with patch.object(prepare, "check_keystore", side_effect=prepare.SigningError("wrong certificate")):
            with self.assertRaises(prepare.SigningError):
                prepare.restore(json.dumps(self.secret), self.root, self.expected)
        self.assertFalse((self.root / "keystore.p12").exists())
        self.assertFalse((self.root / "key.properties").exists())

    def test_passwords_are_passed_only_through_environment(self):
        with patch.object(prepare, "find_tool", return_value=Path("keytool")), \
                patch.object(prepare, "run_tool", return_value=b"test-certificate") as run:
            prepare.check_keystore(self.root / "key.p12", self.secret, self.expected)
        command = run.call_args.args[0]
        self.assertNotIn(self.secret["storePassword"], command)
        self.assertEqual(run.call_args.kwargs["env"]["DD_STORE_PASSWORD"], self.secret["storePassword"])
        self.assertNotIn("DDNOVEL_SIGNING_JSON", run.call_args.kwargs["env"])

    def test_keystore_certificate_mismatch_is_fatal(self):
        with patch.object(prepare, "find_tool", return_value=Path("keytool")), \
                patch.object(prepare, "run_tool", return_value=b"other-certificate"):
            with self.assertRaises(prepare.SigningError):
                prepare.check_keystore(self.root / "key.p12", self.secret, self.expected)

    def test_java_property_escaping(self):
        self.assertEqual(prepare.property_value("D:\\key p12\n密"), "D\\:\\\\key\\ p12\\n\\u5bc6")
        self.assertEqual(prepare.property_value("😀"), "\\ud83d\\ude00")

    def test_windows_apksigner_uses_java_jar_without_cmd(self):
        launcher = self.root / "apksigner.bat"
        jar = self.root / "lib" / "apksigner.jar"
        jar.parent.mkdir(); jar.write_bytes(b"test")
        with patch.object(prepare, "find_tool", return_value=Path("java.exe")):
            self.assertEqual(prepare.tool_command(launcher), ["java.exe", "-jar", str(jar)])

    @staticmethod
    def pem(der):
        return b"-----BEGIN CERTIFICATE-----\r\n" + base64.b64encode(der) + b"\r\n-----END CERTIFICATE-----\r\n"

    def test_verification_hashes_pem_der_on_either_stream_without_display_labels(self):
        pem = self.pem(b"test-certificate")
        with patch.object(sign_apk, "find_tool", return_value=Path("apksigner")):
            for stdout, stderr in [(pem, b""), (b"", pem), (pem, pem), (b"SDK range/localized labels\n" + pem + pem, b"")]:
                result = subprocess.CompletedProcess([], 0, stdout, stderr)
                with self.subTest(stdout=stdout, stderr=stderr), patch.object(sign_apk.subprocess, "run", return_value=result) as run:
                    sign_apk.verify_apk("sample.apk", self.expected)
                    self.assertIn("--print-certs-pem", run.call_args.args[0])

    def test_missing_wrong_extra_malformed_pem_and_failed_crypto_verification_are_rejected(self):
        pem = self.pem(b"test-certificate")
        for output, code in [(b"no cert", 0), (self.pem(b"wrong"), 0), (pem + self.pem(b"extra signer"), 0),
                             (pem + b"-----BEGIN CERTIFICATE-----", 0),
                             (b"-----BEGIN CERTIFICATE-----\n%%%\n-----END CERTIFICATE-----", 0), (pem, 1)]:
            result = subprocess.CompletedProcess([], code, output, b"public verifier diagnostics")
            with self.subTest(output=output, code=code), patch.object(sign_apk, "find_tool", return_value=Path("apksigner")), \
                    patch.object(sign_apk.subprocess, "run", return_value=result), contextlib.redirect_stderr(io.StringIO()) as diagnostic:
                with self.assertRaises(prepare.SigningError) as caught:
                    sign_apk.verify_apk("sample.apk", self.expected)
                self.assertIn("expected=" + self.expected, str(caught.exception))
                self.assertIn("public verifier diagnostics", diagnostic.getvalue())

    def test_no_secret_build_is_explicitly_unsigned_and_cleans_stale_files(self):
        certificate = self.root / "certificate.sha256"
        certificate.write_text(self.expected)
        (self.root / "key.properties").write_text("stale")
        output = self.root / "outputs.txt"
        with patch.dict(os.environ, {"DDNOVEL_SIGNING_JSON": "", "GITHUB_OUTPUT": str(output)}), \
                patch("sys.argv", ["prepare_signing.py", "--output-directory", str(self.root), "--certificate-sha256", str(certificate)]):
            prepare.main()
        self.assertIn("signing_available=false", output.read_text())
        self.assertFalse((self.root / "key.properties").exists())

    def test_local_signing_refuses_to_overwrite_input_or_existing_output(self):
        apk = self.root / "app.apk"; apk.write_bytes(b"original")
        with self.assertRaises(prepare.SigningError):
            sign_apk.sign_apk(apk, "unused.json", apk, self.expected)
        self.assertEqual(apk.read_bytes(), b"original")


if __name__ == "__main__":
    unittest.main()
