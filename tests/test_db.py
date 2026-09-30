import gzip

from riot_meta.db import split_batches, sql_files


def test_split_batches_on_go_lines_only():
    script = "SELECT 1;\nGO\nSELECT 'GO' AS x;\n  go  \nSELECT 3\n"
    assert split_batches(script) == ["SELECT 1;", "SELECT 'GO' AS x;", "SELECT 3"]


def test_every_sql_script_splits_into_batches():
    scripts = sql_files()
    assert scripts[0].name == "01_database.sql"
    for path in scripts:
        assert split_batches(path.read_text()), path.name


def test_payload_compression_round_trips_unicode():
    # The fetcher stores UTF-16LE GZIP so T-SQL's CAST(DECOMPRESS(x) AS NVARCHAR(MAX)) can read it.
    text = '{"riotIdGameName": "Faker 페이커", "info": {}}'
    assert gzip.decompress(gzip.compress(text.encode("utf-16-le"))).decode("utf-16-le") == text
