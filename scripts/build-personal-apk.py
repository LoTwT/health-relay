#!/usr/bin/env python3
"""Build a signed personal APK without placing signing secrets in Gradle arguments."""
import os
import subprocess
from pathlib import Path

repository = Path(__file__).resolve().parents[1]
signing = Path.home() / 'Library/Application Support/health-relay/signing'
environment = os.environ.copy()
keystore = Path(environment.get('HEALTH_RELAY_KEYSTORE', signing / 'release.jks'))
password_file = Path(environment.get('HEALTH_RELAY_PASSWORD_FILE', signing / 'release-password'))
if not keystore.is_file() or not password_file.is_file():
    raise SystemExit('Missing personal keystore/password file. See docs/setup.md; never commit signing files.')
environment['HEALTH_RELAY_KEYSTORE'] = str(keystore)
environment['HEALTH_RELAY_STORE_PASSWORD'] = password_file.read_text().strip()
environment['HEALTH_RELAY_KEY_PASSWORD'] = environment.get('HEALTH_RELAY_KEY_PASSWORD', environment['HEALTH_RELAY_STORE_PASSWORD'])
environment['HEALTH_RELAY_KEY_ALIAS'] = environment.get('HEALTH_RELAY_KEY_ALIAS', 'health-relay')
subprocess.run([str(repository / 'android/gradlew'), '-p', str(repository / 'android'), ':app:assembleRelease'], env=environment, check=True)
