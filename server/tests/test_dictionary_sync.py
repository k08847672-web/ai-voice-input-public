from dataclasses import replace
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from voice_input_server.app import create_app
from voice_input_server.config import Settings
from voice_input_server.dictionary_sync import DictionaryStorageError


def test_dictionary_sync_requires_token_and_preserves_revision(tmp_path: Path) -> None:
    settings = replace(
        Settings.from_env(), bearer_token="test-token", dictionary_sync_dir=str(tmp_path)
    )
    headers = {"Authorization": "Bearer test-token"}
    with TestClient(create_app(settings)) as client:
        assert client.get("/v1/dictionary").status_code == 401
        assert client.put("/v1/dictionary", json={"revision": 0, "entries": {}}).status_code == 401
        assert client.get("/v1/dictionary", headers=headers).json() == {
            "revision": 0,
            "entries": {},
        }
        saved = client.put(
            "/v1/dictionary",
            headers={**headers, "If-Match": "0"},
            json={"revision": 0, "entries": {"误听": "GitHub"}},
        )
        assert saved.status_code == 200
        assert saved.json() == {"revision": 1, "entries": {"误听": "GitHub"}}
        assert saved.headers["cache-control"] == "no-store"
        assert client.put(
            "/v1/dictionary",
            headers={**headers, "If-Match": "0"},
            json={"revision": 0, "entries": {}},
        ).status_code == 409
        assert client.get("/v1/dictionary", headers=headers).json() == saved.json()

    encrypted = (tmp_path / "dictionary.sync.enc").read_bytes()
    assert "误听".encode() not in encrypted
    assert b"GitHub" not in encrypted
    assert (tmp_path / "dictionary.sync.key").stat().st_mode & 0o077 == 0
    assert (tmp_path / "dictionary.sync.enc").stat().st_mode & 0o077 == 0
    with TestClient(create_app(settings)) as restarted:
        assert restarted.get("/v1/dictionary", headers=headers).json() == saved.json()


def test_dictionary_sync_rejects_invalid_payload_and_corruption(tmp_path: Path) -> None:
    settings = replace(
        Settings.from_env(), bearer_token="test-token", dictionary_sync_dir=str(tmp_path)
    )
    headers = {"Authorization": "Bearer test-token", "If-Match": "0"}
    with TestClient(create_app(settings)) as client:
        assert client.put(
            "/v1/dictionary",
            headers=headers,
            json={"revision": 0, "entries": {"": "value"}},
        ).status_code == 400
        assert client.put(
            "/v1/dictionary",
            headers={**headers, "If-Match": "wrong"},
            json={"revision": 0, "entries": {}},
        ).status_code == 400
        assert client.put(
            "/v1/dictionary",
            headers=headers,
            json={"revision": 0, "entries": {"one": "two"}},
        ).status_code == 200
    (tmp_path / "dictionary.sync.enc").write_bytes(b"corrupted")
    with pytest.raises(DictionaryStorageError, match="invalid"):
        create_app(settings)


def test_sync_is_disabled_without_private_directory() -> None:
    settings = replace(Settings.from_env(), bearer_token="test-token", dictionary_sync_dir="")
    with TestClient(create_app(settings)) as client:
        response = client.get(
            "/v1/dictionary", headers={"Authorization": "Bearer test-token"}
        )
        assert response.status_code == 503
