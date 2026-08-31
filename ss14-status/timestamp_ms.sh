#!/usr/bin/env bash
# epoch-ms of an RFC3339 timestamp (SS14 round_start_time), via GNU date.
# Prints a bare number, or "__INVALID__" when unparseable.
ts="${1:?usage: timestamp_ms.sh <rfc3339>}"
out="$(date -d "$ts" +%s%3N 2>/dev/null)" || { echo "__INVALID__"; exit 1; }
if [ "$out" = "" ]; then echo "__INVALID__"; exit 1; fi
echo "$out"