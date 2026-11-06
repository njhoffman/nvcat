"""Thin client for the benchmarks/worker trial: asks the worker for one preview and prints it. Run with python3 -I -S."""
import json
import os
import socket
import sys

connection = socket.socket(socket.AF_UNIX)
connection.connect(sys.argv[1])
connection.sendall(json.dumps({"path": sys.argv[2], "width": int(sys.argv[3]), "height": int(sys.argv[4]),
                                "environment": {k: v for k, v in os.environ.items()
                                                if k.startswith("NVCAT_") or k in ("NO_COLOR", "XDG_CONFIG_HOME", "HOME")}}).encode() + b"\n")
status = connection.recv(1)
while chunk := connection.recv(1 << 16):
  (sys.stdout.buffer if status == b"O" else sys.stderr.buffer).write(chunk)
sys.exit(0 if status == b"O" else 1)
