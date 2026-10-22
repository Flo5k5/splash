import json
import unittest

from dev.tests.server_fixtures import FakeRuntime, Harness, Plan
from server import protocol as wire

CHAT = ("/v1/chat/completions", {"messages": [{"role": "user", "content": "Hi"}]})
NO_STEER = wire.RequestFlag.NO_STEER
IDENTITY = "digest:project:1.0:20-56"


class ControlVectorTests(unittest.TestCase):
    def harness(self, *plans, **options):
        runtime = FakeRuntime(*plans)
        harness = Harness(runtime, **options)
        self.addCleanup(harness.close)
        return harness, runtime

    def test_without_a_vector_the_field_is_absent_or_false(self):
        harness, runtime = self.harness(
            *(Plan([[4]], reason="length") for _ in range(3))
        )
        for fields in ({}, {"control_vector": False}):
            status, _, payload = harness.request(
                "POST", CHAT[0], {**CHAT[1], "max_tokens": 1, **fields}
            )
            self.assertEqual(status, 200, payload)
        self.assertEqual([r.frame.flags for r in runtime.requests], [0, 0])

    def test_true_without_a_vector_is_a_request_error(self):
        harness, runtime = self.harness()
        status, _, payload = harness.request(
            "POST", CHAT[0], {**CHAT[1], "control_vector": True}
        )
        self.assertEqual(status, 400)
        self.assertIn("no control vector", json.loads(payload)["error"]["message"])
        self.assertEqual(len(runtime.requests), 0)

    def test_a_loaded_vector_steers_by_default_and_opts_out(self):
        harness, runtime = self.harness(
            *(Plan([[4]], reason="length") for _ in range(3)),
            control_vector_identity=IDENTITY,
        )
        for fields in ({}, {"control_vector": True}, {"control_vector": False}):
            status, _, payload = harness.request(
                "POST", CHAT[0], {**CHAT[1], "max_tokens": 1, **fields}
            )
            self.assertEqual(status, 200, payload)
        self.assertEqual([r.frame.flags for r in runtime.requests], [0, 0, NO_STEER])

    def test_a_loaded_vector_salts_the_cache_by_steering_state(self):
        harness, runtime = self.harness(
            *(Plan([[4]], reason="length") for _ in range(4)),
            control_vector_identity=IDENTITY,
        )
        for fields in ({}, {}, {"control_vector": False}, {"control_vector": False}):
            status, _, payload = harness.request(
                "POST", CHAT[0], {**CHAT[1], "max_tokens": 1, **fields}
            )
            self.assertEqual(status, 200, payload)
        salts = [r.frame.cache_salt for r in runtime.requests]
        self.assertNotEqual(salts[0], salts[2])
        self.assertEqual(salts[0], salts[1])
        self.assertEqual(salts[2], salts[3])

    def test_the_field_must_be_a_boolean(self):
        harness, runtime = self.harness(control_vector_identity=IDENTITY)
        for value in (1, "true", {}):
            status, _, payload = harness.request(
                "POST", CHAT[0], {**CHAT[1], "control_vector": value}
            )
            self.assertEqual(status, 400)
            self.assertEqual(
                json.loads(payload)["error"]["message"],
                "control_vector must be a boolean",
            )


if __name__ == "__main__":
    unittest.main()
