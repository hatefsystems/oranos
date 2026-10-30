"""Regression tests for human-readable, bounded Git progress output."""
import subprocess
import sys
import unittest
from pathlib import Path

FORMATTER = Path(__file__).resolve().parents[1] / "format-git-progress.py"


def format_output(data: bytes):
    run = subprocess.run(
        [sys.executable, "-u", str(FORMATTER)],
        input=data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    return run.stdout.decode().splitlines()


class GitProgressTests(unittest.TestCase):
    def test_carriage_return_updates_are_lines(self):
        output = format_output(
            b"Receiving objects:   0% (0/100)\r"
            b"Receiving objects:   2% (2/100)\r"
            b"Receiving objects:   5% (5/100)\r"
            b"Receiving objects: 100% (100/100), 1.2 GiB | 4 MiB/s\n"
        )
        self.assertEqual(len(output), 3)
        self.assertIn("0%", output[0])
        self.assertIn("5%", output[1])
        self.assertIn("100%", output[2])

    def test_errors_are_never_suppressed(self):
        output = format_output(
            b"Receiving objects:  10% (10/100)\r"
            b"fatal: GnuTLS handshake failed: connection terminated\n"
        )
        self.assertTrue(any("GnuTLS handshake failed" in line for line in output))

    def test_phase_changes_and_last_line_preserved(self):
        output = format_output(
            b"remote: Counting objects: 100% (7/7)\r"
            b"Receiving objects:  10% (1/10)\r"
            b"Resolving deltas:  50% (5/10)\r"
            b"done"
        )
        self.assertEqual(len(output), 4)
        self.assertEqual(output[-1], "done")

    def test_duplicate_100_percent_progress_suppressed(self):
        output = format_output(
            b"Receiving objects: 100% (10/10)\r"
            b"Receiving objects: 100% (10/10)\r"
        )
        self.assertEqual(len(output), 1)


if __name__ == "__main__":
    unittest.main()
