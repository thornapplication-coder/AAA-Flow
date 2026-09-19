#!/usr/bin/env bash
# Spielt alle Migrationen, den Seed und die SQL-Tests in eine frische lokale
# PostgreSQL-Datenbank ein. Erwartet einen laufenden PostgreSQL-Server
# (>= 15) und einen Superuser. Verbindung über PG* -Umgebungsvariablen.
#
#   PGUSER=postgres PGHOST=localhost ./scripts/db-check.sh
#
# Auf Supabase selbst: `supabase db reset` (Docker) bzw. `supabase db push`.
set -euo pipefail
shopt -s nullglob
cd "$(dirname "$0")/.."
DB="${PCC_TEST_DB:-pcc_check}"
PSQL="psql -v ON_ERROR_STOP=1 -X -q"

echo "==> Datenbank $DB neu anlegen"
$PSQL -d postgres -c "drop database if exists \"$DB\""
$PSQL -d postgres -c "create database \"$DB\""

echo "==> Auth-Shim"
$PSQL -d "$DB" -f scripts/local/auth_shim.sql

for f in supabase/migrations/*.sql; do
  echo "==> Migration $(basename "$f")"
  $PSQL -d "$DB" -f "$f"
done

for f in supabase/seed*.sql; do
  echo "==> Seed $(basename "$f")"
  $PSQL -d "$DB" -f "$f"
done

# Jede bestandene Prüfung meldet sich mit „ok - …". Die Zahl wird gezählt und
# gegen eine Untergrenze gehalten: ein Testlauf, der still weniger prüft als
# zuvor, ist kein grüner Testlauf.
MIN_OK="${PCC_MIN_OK:-205}"
OK_COUNT=0
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
for f in supabase/tests/*.sql; do
  echo "==> Test $(basename "$f")"
  $PSQL -d "$DB" -f "$f" 2>&1 | tee "$LOG"
  # Der Testlauf steht links in der Pipe; sein Fehler darf nicht im tee untergehen.
  test "${PIPESTATUS[0]}" -eq 0
  n=$(grep -c "ok - " "$LOG" || true)
  OK_COUNT=$((OK_COUNT + n))
done

echo "==> $OK_COUNT SQL-Prüfungen bestanden (Untergrenze $MIN_OK)"
if [ "$OK_COUNT" -lt "$MIN_OK" ]; then
  echo "FEHLER: nur $OK_COUNT Prüfungen — Tests fehlen oder liefen nicht durch" >&2
  exit 1
fi
echo "==> OK: Migrationen, Seed und Tests fehlerfrei"
