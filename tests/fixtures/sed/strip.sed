# Strip trailing whitespace and collapse blank lines.
s/[[:space:]]*$//
/^$/{
  N
  /^\n$/D
}
y/abc/xyz/
