#!/usr/bin/env sh

set -Eeuo pipefail


# ---- Connection & credentials (override via env) ----
PGHOST="${PGHOST:-postgres}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"             # superuser
PGPASSWORD="${PGPASSWORD:-${POSTGRES_PASSWORD:-}}"

DISCOURSE_DB_NAME="${DISCOURSE_DB_NAME:-discourse}"
DISCOURSE_DB_USER="${DISCOURSE_DB_USER:-discourse}"
: "${DISCOURSE_DB_PASSWORD:?set DISCOURSE_DB_PASSWORD}"


# ---- Helpers ----
psql_super() { PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -v ON_ERROR_STOP=1 -qtA "$@"; }
psql_db()    { PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DISCOURSE_DB_NAME" -v ON_ERROR_STOP=1 -qtA "$@"; }


# ---- Role ----
if ! psql_super -c "SELECT 1 FROM pg_roles WHERE rolname='${DISCOURSE_DB_USER}'" | grep -q 1; then
  psql_super -c "CREATE ROLE ${DISCOURSE_DB_USER} LOGIN PASSWORD '${DISCOURSE_DB_PASSWORD}'"
fi


# ---- Database ----
if ! psql_super -c "SELECT 1 FROM pg_database WHERE datname='${DISCOURSE_DB_NAME}'" | grep -q 1; then
  psql_super -c "CREATE DATABASE ${DISCOURSE_DB_NAME} OWNER ${DISCOURSE_DB_USER} ENCODING 'UTF8'"
fi


# ---- Required extensions for Discourse (& AI plugin) ----
for ext in hstore pg_trgm vector pg_cjk_parser; do
  psql_db -c "CREATE EXTENSION IF NOT EXISTS ${ext};" || {
    echo "ERROR: extension ${ext} not available; ensure it is installed on the server (package or compiled)." >&2
    exit 1
  }
done
# keep pgvector current if possible
psql_db -c "ALTER EXTENSION vector UPDATE;" || true  # harmless if already latest


# ---- pg_cjk_parser parser + config (idempotent) ----
psql_db <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_ts_parser WHERE prsname='pg_cjk_parser') THEN
    CREATE TEXT SEARCH PARSER public.pg_cjk_parser (
      START = prsd2_cjk_start,
      GETTOKEN = prsd2_cjk_nexttoken,
      END = prsd2_cjk_end,
      LEXTYPES = prsd2_cjk_lextype,
      HEADLINE = prsd2_cjk_headline
    );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_ts_config WHERE cfgname='config_2_gram_cjk') THEN
    CREATE TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ( PARSER = pg_cjk_parser );
    
    -- Add mappings only when creating the configuration for the first time
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR asciihword WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR cjk WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR email WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR asciiword WITH english_stem;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR entity WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR file WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR float WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR host WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR hword WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR hword_asciipart WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR hword_numpart WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR hword_part WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR int WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR numhword WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR numword WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR protocol WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR sfloat WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR tag WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR uint WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR url WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR url_path WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR version WITH simple;
    ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR word WITH simple;
  END IF;
END $$;
SQL


# ---- Make CJK config the DEFAULT for this database ----
psql_super -c "ALTER DATABASE ${DISCOURSE_DB_NAME} SET default_text_search_config = 'public.config_2_gram_cjk';"

# Test Chinese/Japanese parsing (fatal on failure)
OUTPUT=$(psql -h postgres -U discourse -d "${DISCOURSE_DB_NAME:-discourse}" -At -v ON_ERROR_STOP=1 -c "
SET default_text_search_config = 'public.config_2_gram_cjk';
WITH v AS (
  SELECT to_tsvector('Doraemnon Nobita「ドラえもん のび太の牧場物語」多拉A梦 野比大雄χΨψΩω') AS tv
)
SELECT (tv @@ plainto_tsquery('のび太')) AND (tv @@ plainto_tsquery('野比大雄')) FROM v;
")
echo "CJK JP/CN test: $OUTPUT"
if ! echo "$OUTPUT" | grep -q "^t$"; then
  echo "Chinese/Japanese 2-gram parser test FAILED"
  exit 1
fi

# Test Korean parsing (fatal on failure)
OUTPUT=$(psql -h postgres -U discourse -d "${DISCOURSE_DB_NAME:-discourse}" -At -v ON_ERROR_STOP=1 -c "
SET default_text_search_config = 'public.config_2_gram_cjk';
WITH v AS (
  SELECT to_tsvector('大韩민국개인정보의 수집 및 이용 목적(「개인정보 보호법」 제15조)') AS tv
)
SELECT tv @@ plainto_tsquery('大韩민국개인정보') FROM v;
")
echo "CJK KR test: $OUTPUT"
if ! echo "$OUTPUT" | grep -q "^t$"; then
  echo "Korean 2-gram parser test FAILED"
  exit 1
fi

echo "All CJK parser smoke tests passed successfully!"


echo "✅ Discourse DB '${DISCOURSE_DB_NAME}' ready: role, extensions (hstore, pg_trgm, vector, pg_cjk_parser), CJK config."
