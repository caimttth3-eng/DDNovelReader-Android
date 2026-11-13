"""Align/sign an APK with the pinned fixed key, or verify its certificate."""
import argparse
import hashlib
from pathlib import Path
import re
import sys
import tempfile

from prepare_signing import (SigningError, check_keystore, find_tool, fingerprint,
                             password_env, private_write, read_secret, run_tool, tool_command)


def verify_apk(apk, expected, apksigner=None):
    result = run_tool(tool_command(find_tool("apksigner", apksigner)) +
                      ["verify", "--verbose", "--print-certs", str(apk)]).decode("utf-8", errors="replace")
    certificates = re.findall(r"Signer #\d+ certificate SHA-256 digest:\s*([0-9a-fA-F]+)", result)
    if len(certificates) != 1 or certificates[0].lower() != expected:
        raise SigningError("APK signer certificate does not match the pinned certificate.")


def sign_apk(apk, secret_path, output, expected, apksigner=None, zipalign=None, keytool=None):
    apk, output = Path(apk).resolve(), Path(output).resolve()
    if apk == output or not apk.is_file() or output.exists():
        raise SigningError("Input must exist, and output must be a new, separate APK path.")
    secret, payload = read_secret(Path(secret_path).read_text(encoding="utf-8-sig"))
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ddnovel-sign-") as temporary:
        temporary = Path(temporary)
        keystore, aligned, signed = temporary / "keystore.p12", temporary / "aligned.apk", temporary / "signed.apk"
        private_write(keystore, payload)
        check_keystore(keystore, secret, expected, keytool)
        align = tool_command(find_tool("zipalign", zipalign))
        run_tool(align + ["-P", "16", "-f", "4", str(apk), str(aligned)])
        run_tool(tool_command(find_tool("apksigner", apksigner)) + [
            "sign", "--ks", str(keystore), "--ks-type", "PKCS12", "--ks-key-alias", secret["keyAlias"],
            "--ks-pass", "env:DD_STORE_PASSWORD", "--key-pass", "env:DD_KEY_PASSWORD",
            "--v4-signing-enabled", "false", "--out", str(signed), str(aligned),
        ], env=password_env(secret))
        verify_apk(signed, expected, apksigner)
        run_tool(align + ["-c", "-P", "16", "4", str(signed)])
        # Publish only after successful signature and alignment checks.
        with open(output, "xb") as target:
            target.write(signed.read_bytes())
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(output.suffix + ".sha256").write_text(f"{digest}  {output.name}\n", encoding="ascii")
    print(f"Signed and verified with certificate SHA-256: {expected}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", required=True)
    parser.add_argument("--secret-json")
    parser.add_argument("--output")
    parser.add_argument("--certificate-sha256", default="android/signing-certificate.sha256")
    parser.add_argument("--apksigner")
    parser.add_argument("--zipalign")
    parser.add_argument("--keytool")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    try:
        expected = fingerprint(args.certificate_sha256)
        if args.verify_only:
            verify_apk(args.apk, expected, args.apksigner)
            print(f"Verified APK certificate SHA-256: {expected}")
        else:
            if not args.secret_json or not args.output:
                parser.error("Signing requires --secret-json and --output.")
            sign_apk(args.apk, args.secret_json, args.output, expected, args.apksigner, args.zipalign, args.keytool)
    except (SigningError, OSError) as error:
        print(f"APK signing/verification failed: {error}", file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
