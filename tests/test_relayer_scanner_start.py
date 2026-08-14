import importlib.util
import pathlib
import unittest


SCRIPT = (
    pathlib.Path(__file__).parents[1]
    / "ansible/playbooks/l1/files/relayer-scanner-start.py"
)
spec = importlib.util.spec_from_file_location("relayer_scanner_start", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ScannerStartTests(unittest.TestCase):
    manager = "0x00000000000000000000000000000000000000aa"
    settings_selector = "0x736c87be"
    validators_selector = "0x20d91b7a"

    def response_call(self, receipts, selectors=None, finalized=100, canonical=True, target=None):
        selectors = selectors or {tx_hash: self.settings_selector for tx_hash in receipts}

        def call(method, params):
            if method == "eth_getTransactionByHash":
                return {
                    "hash": params[0],
                    "to": target or self.manager,
                    "input": selectors[params[0]] + "00" * 32,
                }
            if method == "eth_getTransactionReceipt":
                return receipts[params[0]]
            if params[0] == "finalized":
                return {"number": hex(finalized), "hash": "0xfinal"}
            receipt = next(r for r in receipts.values() if r["blockNumber"] == params[0])
            return {"number": params[0], "hash": receipt["blockHash"] if canonical else "0xother"}

        return call

    def test_uses_earliest_finalized_canonical_receipt(self):
        receipts = {
            "0xaaa": {"status": "0x1", "blockNumber": "0x20", "blockHash": "0xa20", "logs": [{"address": self.manager}]},
            "0xbbb": {"status": "0x1", "blockNumber": "0x18", "blockHash": "0xb18", "logs": [{"address": self.manager}]},
        }
        anchors = [
            {"txHash": "0xaaa", "selector": self.settings_selector},
            {"txHash": "0xbbb", "selector": self.validators_selector},
        ]
        selectors = {
            "0xaaa": self.settings_selector,
            "0xbbb": self.validators_selector,
        }
        result = module.derive_start(anchors, [self.manager], self.response_call(receipts, selectors))
        self.assertTrue(result["derived"])
        self.assertEqual(result["startBlock"], 0x18)

    def test_missing_reverted_unfinalized_or_noncanonical_falls_back_to_genesis(self):
        base = {"0xaaa": {"status": "0x1", "blockNumber": "0x20", "blockHash": "0xa20", "logs": [{"address": self.manager}]}}
        cases = [
            ({}, self.response_call({}), "missing", [self.manager]),
            ({"0xaaa": {**base["0xaaa"], "status": "0x0"}}, None, "reverted", [self.manager]),
            (base, self.response_call(base, finalized=0x1F), "unfinalized", [self.manager]),
            (base, self.response_call(base, canonical=False), "noncanonical", [self.manager]),
            (base, self.response_call(base, target="0x00000000000000000000000000000000000000ff"), "wrong target", [self.manager]),
            (base, self.response_call(base, selectors={"0xaaa": self.validators_selector}), "wrong selector", [self.manager]),
            ({"0xaaa": {**base["0xaaa"], "logs": [{"address": "0x00000000000000000000000000000000000000ff"}]}}, None, "wrong log", [self.manager]),
        ]
        for receipts, call, name, expected in cases:
            with self.subTest(name=name):
                if name == "missing":
                    result = module.derive_start([], expected, call)
                else:
                    result = module.derive_start(
                        [{"txHash": "0xaaa", "selector": self.settings_selector}],
                        expected,
                        call or self.response_call(receipts),
                    )
                self.assertFalse(result["derived"])
                self.assertEqual(result["startBlock"], 0)


if __name__ == "__main__":
    unittest.main()
