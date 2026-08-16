import asyncio
import json
import sys
import time
import unittest
from pathlib import Path
from typing import Any


ENGINE_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ENGINE_DIR))

from live_mirror import (  # noqa: E402
    AppLookupError,
    AppRecord,
    ForegroundApp,
    MirrorEngine,
    _compact_app_catalog,
    _normalized_app_key,
    _resolve_app_record,
)


def make_engine() -> MirrorEngine:
    engine = object.__new__(MirrorEngine)
    engine._rsd = object()
    engine._foreground_app = None
    engine._foreground_monitor_connected = False
    engine._foreground_monitor_error = None
    engine._foreground_last_state = "unknown"
    engine._foreground_last_transition_at = None
    engine._foreground_condition = asyncio.Condition()
    engine._app_catalog = ()
    engine._app_catalog_loaded_at = 0.0
    engine._app_catalog_lock = asyncio.Lock()
    return engine


class FakeAppBackend:
    def __init__(self, apps: list[dict[str, Any]]) -> None:
        self.apps = apps
        self.list_calls = 0
        self.launches: list[tuple[str, bool, bool]] = []
        self.connects = 0
        self.closes = 0
        self.launch_response: Any = {
            "processToken": {"processIdentifier": 321},
        }

    def service(self):
        backend = self

        class Service:
            async def connect(self) -> None:
                backend.connects += 1

            async def close(self) -> None:
                backend.closes += 1

            async def list_apps(self, **_: Any):
                backend.list_calls += 1
                return backend.apps

            async def launch_application(
                self,
                bundle_id: str,
                *,
                kill_existing: bool,
                start_suspended: bool,
            ):
                backend.launches.append((bundle_id, kill_existing, start_suspended))
                return backend.launch_response

        return Service()


class AppCatalogTests(unittest.TestCase):
    def test_normalization_is_exact_after_unicode_case_and_whitespace(self) -> None:
        self.assertEqual(_normalized_app_key("  ＩＮＳＴＡＧＲＡＭ  "), "instagram")
        self.assertNotEqual(_normalized_app_key("Instagram Lite"), "instagram")

    def test_catalog_compacts_and_deduplicates_by_bundle(self) -> None:
        catalog = _compact_app_catalog(
            [
                {"name": "Instagram", "bundleIdentifier": "com.burbn.instagram"},
                {"name": "Duplicate", "bundleIdentifier": "COM.BURBN.INSTAGRAM"},
                {"name": "", "bundleIdentifier": "invalid.empty"},
                {"unexpected": True},
            ]
        )
        self.assertEqual(catalog, (AppRecord("Instagram", "com.burbn.instagram"),))

    def test_bundle_or_exact_normalized_name_resolves(self) -> None:
        catalog = (
            AppRecord("Instagram", "com.burbn.instagram"),
            AppRecord("Settings", "com.apple.Preferences"),
        )
        self.assertEqual(
            _resolve_app_record(" COM.BURBN.INSTAGRAM ", catalog).name,
            "Instagram",
        )
        self.assertEqual(
            _resolve_app_record(" settings ", catalog).bundle_id,
            "com.apple.Preferences",
        )

    def test_unique_display_name_prefix_resolves_but_ambiguous_prefix_fails_closed(self) -> None:
        catalog = (
            AppRecord("Instagram", "com.burbn.instagram"),
            AppRecord("Settings", "com.apple.Preferences"),
        )
        self.assertEqual(
            _resolve_app_record("insta", catalog).bundle_id,
            "com.burbn.instagram",
        )
        with self.assertRaises(AppLookupError) as too_short:
            _resolve_app_record("ins", catalog)
        self.assertEqual(too_short.exception.status, 404)
        with self.assertRaises(AppLookupError) as bundle_prefix:
            _resolve_app_record("com.burbn", catalog)
        self.assertEqual(bundle_prefix.exception.status, 404)

        ambiguous_catalog = catalog + (
            AppRecord("Instacart", "com.instacart.client"),
        )
        with self.assertRaises(AppLookupError) as ambiguous:
            _resolve_app_record("insta", ambiguous_catalog)
        self.assertEqual(ambiguous.exception.status, 409)
        self.assertEqual(ambiguous.exception.code, "ambiguous_app_name")
        self.assertEqual(len(ambiguous.exception.candidates), 2)

    def test_ambiguous_and_missing_names_fail_closed(self) -> None:
        catalog = (
            AppRecord("Mail", "com.apple.mobilemail"),
            AppRecord("Mail", "example.mail"),
        )
        with self.assertRaises(AppLookupError) as ambiguous:
            _resolve_app_record("mail", catalog)
        self.assertEqual(ambiguous.exception.status, 409)
        self.assertEqual(ambiguous.exception.code, "ambiguous_app_name")

        with self.assertRaises(AppLookupError) as missing:
            _resolve_app_record("Instagram", catalog)
        self.assertEqual(missing.exception.status, 404)
        self.assertEqual(missing.exception.code, "app_not_found")


class EngineAsyncTests(unittest.IsolatedAsyncioTestCase):
    async def test_foreground_notification_exposes_fresh_bundle_and_clears_on_background(self) -> None:
        engine = make_engine()
        await engine._set_foreground_monitor_state(connected=True)
        consumed = await engine._consume_foreground_notification(
            (
                "applicationStateNotification:",
                [
                    {
                        "displayID": "com.burbn.instagram",
                        "appName": "Instagram",
                        "state": 8,
                        "state_description": "Foreground Running",
                    }
                ],
            )
        )
        self.assertTrue(consumed)
        status = engine._foreground_status()
        self.assertTrue(status["available"])
        self.assertTrue(status["fresh"])
        self.assertEqual(status["bundleId"], "com.burbn.instagram")
        self.assertEqual(status["name"], "Instagram")
        self.assertEqual(status["state"], "Foreground Running")
        self.assertIsInstance(status["timestamp"], float)

        await engine._consume_foreground_notification(
            {
                "displayID": "com.burbn.instagram",
                "appName": "Instagram",
                "state": 4,
                "state_description": "Background Running",
            }
        )
        status = engine._foreground_status()
        self.assertFalse(status["available"])
        self.assertFalse(status["fresh"])
        self.assertEqual(status["state"], "Background Running")

        await engine._consume_foreground_notification(
            {
                "displayID": "com.example.inactive",
                "appName": "Inactive",
                "state": 7,
                "state_description": "Foreground Inactive",
            }
        )
        status = engine._foreground_status()
        self.assertFalse(status["available"])
        self.assertFalse(status["fresh"])
        self.assertEqual(status["state"], "Foreground Inactive")

    async def test_disconnected_monitor_marks_cached_identity_stale(self) -> None:
        engine = make_engine()
        engine._foreground_app = ForegroundApp(
            "com.burbn.instagram",
            "Instagram",
            "Foreground Running",
            time.time(),
        )
        await engine._set_foreground_monitor_state(
            connected=False,
            error="connection lost",
        )
        status = engine._foreground_status()
        self.assertTrue(status["available"])
        self.assertFalse(status["fresh"])
        self.assertEqual(status["monitor"], "retrying")

    async def test_open_app_uses_cached_exact_match_and_never_terminates_existing(self) -> None:
        engine = make_engine()
        backend = FakeAppBackend(
            [
                {"name": "Instagram", "bundleIdentifier": "com.burbn.instagram"},
                {"name": "Settings", "bundleIdentifier": "com.apple.Preferences"},
            ]
        )
        engine._make_app_service = backend.service

        code, payload = await engine._open_app_request(
            json.dumps({"name": " insta "}).encode()
        )
        self.assertEqual(code, 200)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["bundleId"], "com.burbn.instagram")
        self.assertEqual(payload["pid"], 321)
        self.assertTrue(payload["launchAccepted"])
        self.assertFalse(payload["foregroundConfirmed"])
        self.assertEqual(
            backend.launches,
            [("com.burbn.instagram", False, False)],
        )

        code, _ = await engine._open_app_request(
            json.dumps({"bundleId": "COM.BURBN.INSTAGRAM"}).encode()
        )
        self.assertEqual(code, 200)
        self.assertEqual(backend.list_calls, 1)
        self.assertEqual(len(backend.launches), 2)
        self.assertEqual(backend.connects, backend.closes)

    async def test_open_app_rejects_ambiguous_or_malformed_request_before_launch(self) -> None:
        engine = make_engine()
        backend = FakeAppBackend(
            [
                {"name": "Mail", "bundleIdentifier": "com.apple.mobilemail"},
                {"name": "Mail", "bundleIdentifier": "example.mail"},
            ]
        )
        engine._make_app_service = backend.service

        code, payload = await engine._open_app_request(
            json.dumps({"name": "mail"}).encode()
        )
        self.assertEqual(code, 409)
        self.assertEqual(payload["error"]["code"], "ambiguous_app_name")
        self.assertEqual(len(payload["error"]["candidates"]), 2)
        self.assertEqual(backend.launches, [])

        code, payload = await engine._open_app_request(
            json.dumps({"name": "Mail", "bundleId": "example.mail"}).encode()
        )
        self.assertEqual(code, 400)
        self.assertEqual(payload["error"]["code"], "invalid_request")
        self.assertEqual(backend.launches, [])

    async def test_monitor_failure_is_reported_and_retry_sleep_is_cancellable(self) -> None:
        engine = make_engine()

        async def fail_connect():
            raise RuntimeError("DVT unavailable")

        engine._open_foreground_monitor = fail_connect
        task = asyncio.create_task(engine._foreground_monitor_loop())
        for _ in range(20):
            if engine._foreground_monitor_error:
                break
            await asyncio.sleep(0.005)
        self.assertEqual(engine._foreground_monitor_error, "DVT unavailable")
        self.assertFalse(engine._foreground_monitor_connected)
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task


if __name__ == "__main__":
    unittest.main()
