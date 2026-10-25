import io
import json
import urllib.error
from unittest import mock

import plugin
import pytest


def respond(body):
    resp = mock.MagicMock()
    resp.read.return_value = (
        body if isinstance(body, bytes) else json.dumps(body).encode()
    )
    resp.__enter__.return_value = resp
    return resp


def http_error(code):
    return urllib.error.HTTPError("u", code, "err", {}, io.BytesIO(b""))


def authenticate(token="tok", min_role=None, **urlopen):
    headers = {"x-gramps-token": token} if token is not None else {}
    with (
        mock.patch.object(plugin.urllib.request, "urlopen", **urlopen) as m,
        mock.patch.object(plugin, "MIN_ROLE", min_role or plugin.MIN_ROLE),
    ):
        return plugin.authenticate(headers), m


def test_role_at_or_above_min_returns_name():
    name, m = authenticate(return_value=respond({"role": 3}))
    assert name == "editor"
    req = m.call_args.args[0]
    assert req.full_url == "https://gramps.example.org/api/users/-/"
    assert req.get_header("Authorization") == "Bearer tok"
    assert m.call_args.kwargs["timeout"] == 4


def test_role_exactly_min_is_allowed():
    name, _ = authenticate(return_value=respond({"role": 1}))
    assert name == "member"


def test_missing_token_is_none_without_a_call():
    name, m = authenticate(token=None)
    assert name is None
    m.assert_not_called()


@pytest.mark.parametrize("code", [401, 403])
def test_http_error_is_none(code):
    name, _ = authenticate(side_effect=http_error(code))
    assert name is None


@pytest.mark.parametrize(
    "exc", [urllib.error.URLError("down"), TimeoutError(), OSError("x")]
)
def test_transport_errors_are_none(exc):
    name, _ = authenticate(side_effect=exc)
    assert name is None


@pytest.mark.parametrize(
    "body", [b"not json", [1], {"role": "admin"}, {"role": None}, {}, 3]
)
def test_bad_payload_is_none(body):
    name, _ = authenticate(return_value=respond(body))
    assert name is None


def test_role_below_min_raises():
    with pytest.raises(PermissionError):
        authenticate(return_value=respond({"role": 0}))


def test_unconfirmed_and_disabled_are_below_guest():
    with pytest.raises(PermissionError):
        authenticate(return_value=respond({"role": -2}), min_role="guest")
    with pytest.raises(PermissionError):
        authenticate(return_value=respond({"role": -1}), min_role="guest")


def test_nobody_locks_every_role():
    with pytest.raises(PermissionError):
        authenticate(return_value=respond({"role": 5}), min_role="nobody")


def test_unknown_min_role_locks():
    with pytest.raises(PermissionError):
        authenticate(return_value=respond({"role": 5}), min_role="wizard")


def test_release_section_reports_the_version():
    facts = plugin.sections()["release"]()
    assert facts["title"] == "Release"
    assert facts["rows"][0]["value"] == "v26.1.0"
    assert facts["rows"][0]["caption"]


def test_release_value_is_null_when_version_unset():
    with mock.patch.object(plugin, "GRAMPS_WEB_VERSION", ""):
        assert plugin.release()["rows"][0]["value"] is None
