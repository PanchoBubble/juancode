#!/bin/bash
# Stand-in for $JUANCODE_EDITOR (nvim by default) so the openEditor scenario needs
# no real editor installed. Prints the file it was handed and then holds the pty
# open until it is killed, which is all the wire contract cares about.

stty -echo 2>/dev/null
printf 'fake-editor %s\r\n' "$*"

while IFS= read -r line; do
  case "$line" in
  EXIT) exit 0 ;;
  *) printf 'fake-editor\r\n' ;;
  esac
done

exit 0
