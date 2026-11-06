#!/usr/bin/python3
"""Send a request to a worker and print its reply. Usage: worker_ask.py SOCKET JSON"""
import socket
import sys

with socket.socket(socket.AF_UNIX) as connection:
  connection.settimeout(5)
  connection.connect(sys.argv[1])
  connection.sendall(sys.argv[2].encode() + b"\n")
  print(connection.makefile().read())
