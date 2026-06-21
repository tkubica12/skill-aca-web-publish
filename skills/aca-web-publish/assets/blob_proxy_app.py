"""Authenticated ACA proxy for private Azure Blob Storage static content."""

from __future__ import annotations

import base64
from collections.abc import Iterator
import hashlib
import hmac
import json
import mimetypes
import os
import secrets
import time
from typing import Any
from urllib.parse import urlencode
from urllib.parse import unquote

from azure.core.exceptions import ResourceNotFoundError
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, ContainerClient
from fastapi import FastAPI, Header, HTTPException, Request, Response
from fastapi.responses import PlainTextResponse, RedirectResponse, StreamingResponse
import httpx

app = FastAPI(title="ACA private Blob proxy")

_CHUNK_SIZE = 1024 * 1024
_SESSION_COOKIE = "aca_web_session"
_STATE_COOKIE = "aca_web_oauth_state"
_SESSION_TTL_SECONDS = 60 * 60 * 24 * 14


def _csv_env(name: str) -> set[str]:
    return {item.strip().casefold() for item in os.getenv(name, "").split(",") if item.strip()}


def _auth_provider() -> str:
    return os.getenv("AUTH_PROVIDER", "github").strip().casefold() or "github"


def _public_base_url(request: Request) -> str:
    return os.getenv("PUBLIC_BASE_URL", str(request.base_url).rstrip("/")).rstrip("/")


def _public_request_url(request: Request) -> str:
    url = f"{_public_base_url(request)}{request.url.path}"
    return f"{url}?{request.url.query}" if request.url.query else url


def _required_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise RuntimeError(f"{name} must be configured")
    return value


def _session_secret() -> str:
    return _required_env("SESSION_SECRET")


def _b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def _b64url_decode(data: str) -> bytes:
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))


def _sign(value: str) -> str:
    digest = hmac.new(_session_secret().encode("utf-8"), value.encode("utf-8"), hashlib.sha256).digest()
    return _b64url_encode(digest)


def _encode_signed_payload(payload: dict[str, Any]) -> str:
    body = _b64url_encode(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8"))
    return f"{body}.{_sign(body)}"


def _decode_signed_payload(value: str | None) -> dict[str, Any] | None:
    if not value or "." not in value:
        return None
    body, signature = value.rsplit(".", 1)
    if not hmac.compare_digest(signature, _sign(body)):
        return None
    try:
        payload = json.loads(_b64url_decode(body))
    except (ValueError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def _allowed_users() -> set[str]:
    return _csv_env("ALLOWED_USERS")


def _make_session(subject: str, provider: str) -> str:
    return _encode_signed_payload({
        "sub": subject,
        "provider": provider,
        "exp": int(time.time()) + _SESSION_TTL_SECONDS,
    })


def _valid_session(request: Request) -> bool:
    if _auth_provider() == "none":
        return True
    session = _decode_signed_payload(request.cookies.get(_SESSION_COOKIE))
    if not session or int(session.get("exp", 0)) < int(time.time()):
        return False
    return str(session.get("provider", "")).casefold() == _auth_provider() and str(session.get("sub", "")).casefold() in _allowed_users()


def _state_cookie(return_to: str, state: str) -> str:
    return _encode_signed_payload({"state": state, "return_to": return_to, "exp": int(time.time()) + 600})


def _start_oauth(request: Request) -> RedirectResponse:
    provider = _auth_provider()
    if provider == "none":
        return RedirectResponse(str(request.url), status_code=302)
    state = secrets.token_urlsafe(32)
    base_url = _public_base_url(request)
    if provider == "github":
        query = urlencode({
            "client_id": _required_env("GITHUB_CLIENT_ID"),
            "redirect_uri": f"{base_url}/oauth/github/callback",
            "scope": "read:user user:email",
            "state": state,
        })
        location = f"https://github.com/login/oauth/authorize?{query}"
    elif provider == "google":
        query = urlencode({
            "client_id": _required_env("GOOGLE_CLIENT_ID"),
            "redirect_uri": f"{base_url}/oauth/google/callback",
            "response_type": "code",
            "scope": "openid email profile",
            "state": state,
        })
        location = f"https://accounts.google.com/o/oauth2/v2/auth?{query}"
    elif provider == "entra":
        tenant = _required_env("ENTRA_TENANT_ID")
        query = urlencode({
            "client_id": _required_env("ENTRA_CLIENT_ID"),
            "redirect_uri": f"{base_url}/oauth/entra/callback",
            "response_type": "code",
            "scope": "openid email profile User.Read",
            "state": state,
        })
        location = f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize?{query}"
    else:
        raise HTTPException(status_code=500, detail=f"Unsupported AUTH_PROVIDER: {provider}")
    response = RedirectResponse(location, status_code=302)
    response.set_cookie(_STATE_COOKIE, _state_cookie(_public_request_url(request), state), httponly=True, secure=True, samesite="lax", max_age=600)
    return response


def _verify_state(request: Request, state: str) -> str:
    payload = _decode_signed_payload(request.cookies.get(_STATE_COOKIE))
    if not payload or int(payload.get("exp", 0)) < int(time.time()) or not hmac.compare_digest(str(payload.get("state", "")), state):
        raise HTTPException(status_code=401, detail="Invalid OAuth state")
    return str(payload.get("return_to") or "/")


def _exchange_token(url: str, data: dict[str, str]) -> dict[str, Any]:
    with httpx.Client(timeout=20.0) as client:
        response = client.post(url, data=data, headers={"Accept": "application/json"})
        response.raise_for_status()
        payload = response.json()
    if not isinstance(payload, dict) or not payload.get("access_token"):
        raise HTTPException(status_code=401, detail="OAuth provider did not return an access token")
    return payload


def _github_subject(access_token: str) -> str:
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {access_token}",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    with httpx.Client(timeout=20.0) as client:
        user_response = client.get("https://api.github.com/user", headers=headers)
        user_response.raise_for_status()
        user = user_response.json()
        emails_response = client.get("https://api.github.com/user/emails", headers=headers)
        emails_response.raise_for_status()
        emails = emails_response.json()
    login = str(user.get("login", "")).strip().casefold()
    allowed_emails = _csv_env("GITHUB_ALLOWED_EMAILS")
    if allowed_emails:
        verified_emails = {
            str(item.get("email", "")).strip().casefold()
            for item in emails
            if isinstance(item, dict) and item.get("verified")
        }
        if not (verified_emails & allowed_emails):
            raise HTTPException(status_code=403, detail="GitHub email is not allowlisted")
    return login


def _userinfo_subject(url: str, access_token: str) -> str:
    with httpx.Client(timeout=20.0) as client:
        response = client.get(url, headers={"Authorization": f"Bearer {access_token}"})
        response.raise_for_status()
        user = response.json()
    return str(user.get("email") or user.get("userPrincipalName") or user.get("id") or user.get("sub") or "").strip().casefold()


def _complete_login(provider: str, request: Request, code: str, state: str) -> Response:
    return_to = _verify_state(request, state)
    base_url = _public_base_url(request)
    if not code:
        raise HTTPException(status_code=401, detail="Missing OAuth code")
    if provider == "github":
        token = _exchange_token("https://github.com/login/oauth/access_token", {
            "client_id": _required_env("GITHUB_CLIENT_ID"),
            "client_secret": _required_env("GITHUB_CLIENT_SECRET"),
            "code": code,
            "redirect_uri": f"{base_url}/oauth/github/callback",
        })
        subject = _github_subject(str(token["access_token"]))
    elif provider == "google":
        token = _exchange_token("https://oauth2.googleapis.com/token", {
            "client_id": _required_env("GOOGLE_CLIENT_ID"),
            "client_secret": _required_env("GOOGLE_CLIENT_SECRET"),
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": f"{base_url}/oauth/google/callback",
        })
        subject = _userinfo_subject("https://openidconnect.googleapis.com/v1/userinfo", str(token["access_token"]))
    elif provider == "entra":
        tenant = _required_env("ENTRA_TENANT_ID")
        token = _exchange_token(f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token", {
            "client_id": _required_env("ENTRA_CLIENT_ID"),
            "client_secret": _required_env("ENTRA_CLIENT_SECRET"),
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": f"{base_url}/oauth/entra/callback",
        })
        subject = _userinfo_subject("https://graph.microsoft.com/v1.0/me", str(token["access_token"]))
    else:
        raise HTTPException(status_code=500, detail=f"Unsupported provider: {provider}")
    if subject not in _allowed_users():
        raise HTTPException(status_code=403, detail="User is not authorized")
    response = RedirectResponse(return_to, status_code=302)
    response.set_cookie(_SESSION_COOKIE, _make_session(subject, provider), httponly=True, secure=True, samesite="lax", max_age=_SESSION_TTL_SECONDS)
    response.delete_cookie(_STATE_COOKIE)
    return response


def _container_client() -> ContainerClient:
    account_name = os.environ["STORAGE_ACCOUNT_NAME"]
    container_name = os.getenv("BLOB_CONTAINER_NAME", "site")
    service = BlobServiceClient(
        account_url=f"https://{account_name}.blob.core.windows.net",
        credential=DefaultAzureCredential(),
    )
    return service.get_container_client(container_name)


def _blob_name_from_path(path: str) -> str:
    decoded = unquote(path).lstrip("/")
    if not decoded:
        return "index.html"
    if decoded.endswith("/"):
        return f"{decoded}index.html"
    if "\\" in decoded or any(part == ".." for part in decoded.split("/")):
        raise HTTPException(status_code=400, detail="Invalid path")
    return decoded


def _parse_range(range_header: str | None, size: int) -> tuple[int, int] | None:
    if not range_header:
        return None
    if not range_header.startswith("bytes=") or "," in range_header:
        raise HTTPException(status_code=416, detail="Unsupported range")
    start_text, separator, end_text = range_header.removeprefix("bytes=").partition("-")
    if not separator:
        raise HTTPException(status_code=416, detail="Invalid range")
    try:
        if start_text:
            start = int(start_text)
            end = int(end_text) if end_text else size - 1
        else:
            suffix_length = int(end_text)
            if suffix_length == 0:
                raise HTTPException(status_code=416, detail="Invalid range")
            start = max(size - suffix_length, 0)
            end = size - 1
    except ValueError as error:
        raise HTTPException(status_code=416, detail="Invalid range") from error
    if start < 0 or end < start or start >= size:
        raise HTTPException(status_code=416, detail="Range not satisfiable")
    return start, min(end, size - 1)


def _content_type(blob_name: str, blob_content_type: str | None) -> str:
    if blob_content_type and blob_content_type != "application/octet-stream":
        return blob_content_type
    guessed, _ = mimetypes.guess_type(blob_name)
    return guessed or "application/octet-stream"


def _blob_chunks(container: ContainerClient, blob_name: str, offset: int, length: int) -> Iterator[bytes]:
    stream = container.download_blob(blob_name, offset=offset, length=length, max_concurrency=4)
    yield from stream.chunks()


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/login")
def login(request: Request) -> RedirectResponse:
    return _start_oauth(request)


@app.get("/oauth/{provider}/callback")
def oauth_callback(provider: str, request: Request, code: str = "", state: str = "") -> Response:
    if provider.casefold() != _auth_provider():
        raise HTTPException(status_code=400, detail="Unexpected OAuth provider")
    return _complete_login(provider.casefold(), request, code, state)


@app.get("/logout")
def logout() -> PlainTextResponse:
    response = PlainTextResponse("Signed out")
    response.delete_cookie(_SESSION_COOKIE)
    response.delete_cookie(_STATE_COOKIE)
    return response


@app.api_route("/{path:path}", methods=["GET", "HEAD"])
def serve_blob(request: Request, path: str, range_header: str | None = Header(default=None, alias="Range")):
    if not _valid_session(request):
        return _start_oauth(request)
    blob_name = _blob_name_from_path(path)
    container = _container_client()
    blob = container.get_blob_client(blob_name)
    try:
        properties = blob.get_blob_properties()
    except ResourceNotFoundError as error:
        if "." not in blob_name.rsplit("/", maxsplit=1)[-1]:
            return serve_blob(request, f"{blob_name}/", range_header)
        raise HTTPException(status_code=404, detail="Not found") from error
    size = int(properties.size)
    content_type = _content_type(blob_name, properties.content_settings.content_type)
    selected_range = _parse_range(range_header, size)
    headers = {"Accept-Ranges": "bytes", "Cache-Control": "private, max-age=300"}
    if selected_range:
        start, end = selected_range
        length = end - start + 1
        headers["Content-Range"] = f"bytes {start}-{end}/{size}"
        if request.method == "HEAD":
            return Response(status_code=206, headers=headers, media_type=content_type)
        return StreamingResponse(_blob_chunks(container, blob_name, start, length), status_code=206, headers=headers, media_type=content_type)
    if request.method == "HEAD":
        return Response(headers=headers, media_type=content_type)
    return StreamingResponse(_blob_chunks(container, blob_name, 0, size), headers=headers, media_type=content_type)
