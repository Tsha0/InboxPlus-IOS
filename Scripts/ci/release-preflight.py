#!/usr/bin/env python3
import os

REQUIRED = ["APPLE_TEAM_ID", "ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY_B64",
            "IOS_DISTRIBUTION_CERTIFICATE_B64", "IOS_CERTIFICATE_PASSWORD", "IOS_PROVISIONING_PROFILE_B64"]
def missing_settings(environment):
    return [name for name in REQUIRED if not environment.get(name, "").strip()]

if __name__ == "__main__":
    missing = missing_settings(os.environ)
    if missing:
        raise SystemExit("TestFlight configuration missing: " + ", ".join(missing))
    print("Required TestFlight settings are present.")
