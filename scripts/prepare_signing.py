"""Restore a private PKCS12 signing secret and enforce the public certificate pin."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


class SigningError(Exception):
    pass


def fingerprint(path):
    value = re.sub(r"[:\s]", "", Path(path).read_text(encoding="utf-8")).lower()
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        raise SigningError("Public certificate fingerprint must contain exactly 64 hex digits.")
    return value


def read_secret(raw):
    try:
        data = json.loads(raw)
        if not isinstance(data, dict) or data.get("version") != 1 or data.get("storeType") != "PKCS12":
            raise ValueError()
        for field in ("keystoreBase64", "storePassword", "keyAlias", "keyPassword"):
            if not isinstance(data.get(field), str) or not data[field]:
                raise ValueError()
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", data["keyAlias"]):
            raise ValueError()
        payload = base64.b64decode(data["keystoreBase64"], validate=True)
        if not payload or len(payload) > 1024 * 1024:
            raise ValueError()
        return data, payload
    except (ValueError, TypeError, KeyError):
        raise SigningError("Invalid signing JSON; expected schema version 1 and a PKCS12 payload.") from None


def find_tool(name, explicit=None):
    if explicit:
        path = Path(explicit)
        if not path.is_file():
            raise SigningError(f"Required tool not found: {name}.")
        return path
    if name in ("keytool", "java") and os.environ.get("JAVA_HOME"):
        candidate = Path(os.environ["JAVA_HOME"]) / "bin" / (name + (".exe" if os.name == "nt" else ""))
        if candidate.is_file():
            return candidate
    found = shutil.which(name)
    if found:
        return Path(found)
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if sdk:
        names = [name, name + ".exe", name + ".bat"]
        candidates = [p for n in names for p in (Path(sdk) / "build-tools").glob("*/" + n)]
        if candidates:
            return max(candidates, key=lambda p: tuple(int(n) for n in re.findall(r"\d+", p.parent.name)))
    raise SigningError(f"Required tool not found: {name}; set JAVA_HOME/ANDROID_HOME or its explicit path.")


def tool_command(path):
    path = Path(path)
    if path.suffix.lower() == ".jar":
        return [str(find_tool("java")), "-jar", str(path)]
    if path.name.lower() in ("apksigner.bat", "apksigner.cmd"):
        jar = path.parent / "lib" / "apksigner.jar"
        if not jar.is_file():
            raise SigningError("apksigner.jar is missing beside the Windows launcher.")
        return [str(find_tool("java")), "-jar", str(jar)]
    return [str(path)]


def run_tool(command, *, env=None):
    try:
        result = subprocess.run(command, env=env, capture_output=True, check=False, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        raise SigningError("Signing tool could not finish; check the installed JDK/Android Build Tools.") from None
    if result.returncode:
        # Do not print tool stderr, command lines or secret JSON.
        raise SigningError("Signing tool rejected the operation; check the key, passwords and APK.")
    return result.stdout


def private_write(path, payload):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(payload)
    os.chmod(path, 0o600)


def password_env(secret):
    env = dict(os.environ)
    env.pop("DDNOVEL_SIGNING_JSON", None)
    env["DD_STORE_PASSWORD"] = secret["storePassword"]
    env["DD_KEY_PASSWORD"] = secret["keyPassword"]
    return env


def check_keystore(path, secret, expected, keytool=None):
    der = run_tool(tool_command(find_tool("keytool", keytool)) + [
        "-exportcert", "-keystore", str(path), "-alias", secret["keyAlias"],
        "-storetype", "PKCS12", "-storepass:env", "DD_STORE_PASSWORD",
    ], env=password_env(secret))
    if hashlib.sha256(der).hexdigest() != expected:
        raise SigningError("Signing certificate does not match android/signing-certificate.sha256.")


def property_value(value):
    result = ""
    for char in str(value):
        if char in "\\:=#! ":
            result += "\\" + char
        elif char in "\r\n\t\f":
            result += {"\r": "\\r", "\n": "\\n", "\t": "\\t", "\f": "\\f"}[char]
        elif ord(char) > 126 or ord(char) < 32:
            encoded = char.encode("utf-16-be")
            result += "".join("\\u" + encoded[i:i + 2].hex() for i in range(0, len(encoded), 2))
        else:
            result += char
    return result


def cleanup(directory):
    directory = Path(directory).resolve()
    for name in ("keystore.p12", "key.properties"):
        (directory / name).unlink(missing_ok=True)


def restore(raw, directory, expected, keytool=None):
    secret, payload = read_secret(raw)
    directory = Path(directory).resolve()
    keystore = directory / "keystore.p12"
    properties = directory / "key.properties"
    cleanup(directory)
    private_write(keystore, payload)
    try:
        check_keystore(keystore, secret, expected, keytool)
        values = {"storeFile": keystore.as_posix(), "storeType": "PKCS12",
                  "storePassword": secret["storePassword"], "keyAlias": secret["keyAlias"],
                  "keyPassword": secret["keyPassword"]}
        private_write(properties, "".join(k + "=" + property_value(v) + "\n" for k, v in values.items()).encode("ascii"))
        return properties
    except Exception:
        cleanup(directory)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-directory", required=True)
    parser.add_argument("--certificate-sha256", default="android/signing-certificate.sha256")
    parser.add_argument("--keytool")
    parser.add_argument("--cleanup", action="store_true")
    args = parser.parse_args()
    try:
        if args.cleanup:
            cleanup(args.output_directory)
            return
        expected = fingerprint(args.certificate_sha256)
        raw = os.environ.get("DDNOVEL_SIGNING_JSON", "").strip()
        cleanup(args.output_directory)
        properties = restore(raw, args.output_directory, expected, args.keytool) if raw else None
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
                output.write(f"signing_available={'true' if properties else 'false'}\n")
                output.write(f"properties_path={properties or ''}\n")
        print("Fixed signing key verified." if properties else "No signing secret: building an UNSIGNED APK for local signing.")
    except (SigningError, OSError) as error:
        print(f"Signing preparation failed: {error}", file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
