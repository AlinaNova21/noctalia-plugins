#!/usr/bin/env bash
# Read-only sync of the SS14 launcher's favorite servers.
# Prints "Address|Name" per line (Name may be empty).
DB="${1:?usage: import_favorites.sh <settings.db>}"
if [ ! -f "$DB" ]; then echo "__NO_DB__"; exit 1; fi
if ! command -v sqlite3 >/dev/null 2>&1; then echo "__NO_SQLITE__"; exit 1; fi
sqlite3 "$DB" "SELECT COALESCE(Address,''), COALESCE(Name,'') FROM FavoriteServer ORDER BY RaiseTime;"