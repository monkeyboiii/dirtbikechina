#!/bin/sh

set -e  # Exit immediately if a command exits with a non-zero status

# Create the extension
OUTPUT=$(psql -h postgres -U postgres -c 'CREATE EXTENSION pg_cjk_parser;' 2>&1)
echo "$OUTPUT"
if ! echo "$OUTPUT" | grep -q "CREATE EXTENSION"; then
    echo "Failed to create extension"
    exit 1
fi

# Create parser and configuration
psql -h postgres -U postgres -c "CREATE TEXT SEARCH PARSER public.pg_cjk_parser (START = prsd2_cjk_start, GETTOKEN = prsd2_cjk_nexttoken, END = prsd2_cjk_end, LEXTYPES = prsd2_cjk_lextype, HEADLINE = prsd2_cjk_headline); CREATE TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ( PARSER = pg_cjk_parser ); SET default_text_search_config = 'public.config_2_gram_cjk';"

# Add mapping
psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR asciihword WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR cjk WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR email WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR asciiword WITH english_stem;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR entity WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR file WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR float WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR host WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR hword WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR hword_asciipart WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR hword_numpart WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR hword_part WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR int WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR numhword WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR numword WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR protocol WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR sfloat WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR tag WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR uint WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR url WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR url_path WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR version WITH simple;"

psql -h postgres -U postgres -c "ALTER TEXT SEARCH CONFIGURATION public.config_2_gram_cjk ADD MAPPING FOR word WITH simple;"

# Test Chinese/Japanese parsing
OUTPUT=$(psql -h postgres -U postgres -c "SET default_text_search_config = 'public.config_2_gram_cjk'; SELECT to_tsvector('Doraemnon Nobita「ドラえもん のび太の牧場物語」多拉A梦 野比大雄χΨψΩω'), to_tsquery('のび太'), to_tsquery('野比大雄');" 2>&1)
echo "$OUTPUT"
if ! echo "$OUTPUT" | grep -q "| 'のび' <-> 'び太' | '野比' <-> '比大' <-> '大雄'"; then
    echo "Chinese/Japanese not splitted into 2-grams"
    exit 1
fi

# Test Korean parsing
OUTPUT=$(psql -h postgres -U postgres -c "SET default_text_search_config = 'public.config_2_gram_cjk'; SELECT to_tsvector('大韩민국개인정보의 수집 및 이용 목적(「개인정보 보호법」 제15조)'), to_tsquery('「大韩민국개인정보');" 2>&1)
echo "$OUTPUT"
if ! echo "$OUTPUT" | grep -q "「' <-> '大韩' <-> '韩민' <-> '민국' <-> '국개' <-> '개인' <-> '인정' <-> '정보'"; then
    echo "Korean not splitted into 2-grams"
    exit 1
fi

echo "All tests passed successfully!"