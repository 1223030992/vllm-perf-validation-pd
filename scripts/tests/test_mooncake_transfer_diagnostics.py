import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "ops" / "mooncake_transfer_diagnostics.py"
SPEC = importlib.util.spec_from_file_location("mooncake_transfer_diagnostics", str(MODULE_PATH))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MooncakeTransferDiagnosticsTest(unittest.TestCase):
    def test_extracts_topology(self):
        parsed = MODULE.parse_log(
            """
The Mooncake Transfer Engine is using rdma as its protocol.
Transfer Engine RPC using P2P handshake, listening on 13.13.1.1:16922
Device mlx5_0 port 1 is available
Device mlx5_6 port 1 is available
Find best gid index: 3 on mlx5_6 (GID_Index 3)
Topology discovery complete. Found 9 HCAs.
"""
        )
        self.assertEqual(parsed["protocol"], "rdma")
        self.assertEqual(parsed["detected_hcas"], "mlx5_0,mlx5_6")
        self.assertEqual(parsed["detected_hca_count"], 9)
        self.assertEqual(parsed["gid_indices"], "3")
        self.assertEqual(parsed["listening_addresses"], "13.13.1.1:16922")


if __name__ == "__main__":
    unittest.main()
