"""Gramps Web plugin for the status-page core.

authenticate() resolves the caller's role through the site's own API, so the
gated routes work only while Gramps Web is up. The token arrives in
X-Gramps-Token, not Authorization: CloudFront's OAC overwrites Authorization
with its SigV4 signature on the way to the Function URL.
"""

import json
import os
import urllib.error
import urllib.request

SITE_URL = os.environ["SITE_URL"]
MIN_ROLE = os.environ["MIN_ROLE"]
GRAMPS_WEB_VERSION = os.environ.get("GRAMPS_WEB_VERSION", "")
AUTH_TIMEOUT_S = 4

# Upstream's ladder (gramps-web-api). "nobody" is not a real Gramps Web role:
# it maps one past admin so MIN_ROLE = "nobody" can never be satisfied, which
# locks the deployed page for everyone.
ROLES = {
    "disabled": -1,
    "unconfirmed": -2,
    "guest": 0,
    "member": 1,
    "contributor": 2,
    "editor": 3,
    "owner": 4,
    "admin": 5,
    "nobody": 6,
}
ROLE_NAMES = {v: k for k, v in ROLES.items()}


def fetch_role(token):
    """The caller's role int from GET /api/users/-/, or None on any failure."""
    if not token:
        return None
    req = urllib.request.Request(
        f"{SITE_URL}/api/users/-/",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=AUTH_TIMEOUT_S) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except (
        urllib.error.HTTPError,
        urllib.error.URLError,
        TimeoutError,
        ValueError,
        OSError,
    ) as e:
        print(json.dumps({"auth_failed": f"{type(e).__name__}: {e}"}))
        return None
    role = body.get("role") if isinstance(body, dict) else None
    if not isinstance(role, int):
        print(
            json.dumps(
                {"auth_failed": "missing or non-int role in /api/users/-/ response"}
            )
        )
        return None
    return role


def authenticate(headers):
    role = fetch_role(headers.get("x-gramps-token"))
    if role is None:
        return None
    role_name = ROLE_NAMES.get(role, str(role))
    if role < ROLES.get(MIN_ROLE, ROLES["nobody"]):
        raise PermissionError(f"role {role_name} is below min_role {MIN_ROLE}")
    return role_name


def release():
    return {
        "title": "Release",
        "rows": [
            {
                "label": "Gramps Web",
                "value": GRAMPS_WEB_VERSION or None,
                "caption": "Upstream grampsweb image tag the app pipeline builds from.",
            }
        ],
    }


def sections():
    return {"release": release}
