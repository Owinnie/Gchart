"""Spec tests for Athena region / staging-dir resolution.

Mirrors src/common/R/athena_config.R so we can verify the rules without R.
"""

from __future__ import annotations

import unittest


UNUSABLE_ATHENA_OUTPUT_BUCKETS = {"katrin-test"}


def get_env_value(name: str, env: dict[str, str] | None = None) -> str:
    if env is None:
        return ""
    value = env.get(name, "")
    if value is None:
        return ""
    return str(value).strip()


def extract_s3_bucket(uri: str) -> str:
    if not uri:
        return ""
    path = uri.strip()
    if path.lower().startswith("s3://"):
        path = path[5:]
    return path.split("/", 1)[0]


def is_unusable_athena_output_bucket(bucket: str) -> bool:
    if not bucket:
        return True
    return bucket.lower() in UNUSABLE_ATHENA_OUTPUT_BUCKETS


def s3_uri_has_key_prefix(uri: str) -> bool:
    if not uri:
        return False
    path = uri.strip()
    if path.lower().startswith("s3://"):
        path = path[5:]
    return "/" in path


def normalize_s3_uri(value: str, db: str | None = None, query_results_prefix: bool = False) -> str:
    if value is None or not str(value).strip():
        return ""
    uri = str(value).strip()
    if not uri.lower().startswith("s3://"):
        uri = f"s3://{uri}"
    uri = "s3://" + uri[5:]
    if not uri.endswith("/"):
        uri += "/"
    if query_results_prefix and not uri.rstrip("/").endswith("athena-query-results"):
        uri += "athena-query-results/"
    if db:
        if not uri.endswith(f"{db}/"):
            uri += f"{db}/"
    return uri


def resolve_athena_region(secret_region: str | None = None, env: dict[str, str] | None = None) -> str:
    secret_value = (secret_region or "").strip()
    candidates = [
        get_env_value("AWS_REGION", env),
        get_env_value("AWS_DEFAULT_REGION", env),
        secret_value,
        "eu-central-1",
    ]
    return next(value for value in candidates if value)


def staging_candidates(explicit: str | None = None, env: dict[str, str] | None = None):
    return [
        {"value": (explicit or "").strip(), "kind": "staging"},
        {"value": get_env_value("AWS_ATHENA_S3_STAGING_DIR", env), "kind": "staging"},
        {"value": get_env_value("s3_staging_dir", env), "kind": "staging"},
        {"value": get_env_value("athena_s3_output_bucket", env), "kind": "data_bucket"},
        {"value": get_env_value("s3_data_lake_bucket", env), "kind": "data_bucket"},
        {"value": get_env_value("s3_to_redshift_bucket", env), "kind": "data_bucket"},
    ]


def resolve_athena_s3_staging_dir(
    db: str,
    explicit: str | None = None,
    env: dict[str, str] | None = None,
) -> str:
    skipped: list[str] = []
    for candidate in staging_candidates(explicit=explicit, env=env):
        raw = candidate["value"]
        if not raw:
            continue
        bucket = extract_s3_bucket(raw)
        if is_unusable_athena_output_bucket(bucket):
            skipped.append(bucket)
            continue
        use_query_prefix = candidate["kind"] == "data_bucket" and not s3_uri_has_key_prefix(raw)
        uri = normalize_s3_uri(raw, db=db, query_results_prefix=use_query_prefix)
        if uri and not is_unusable_athena_output_bucket(extract_s3_bucket(uri)):
            return uri

    skipped_note = ""
    if skipped:
        skipped_note = f" Ignored leftover bucket(s): {', '.join(dict.fromkeys(skipped))}."
    raise ValueError(
        "No usable Athena query-results bucket configured."
        + skipped_note
        + " Set s3_staging_dir or s3_data_lake_bucket in .Renviron to an existing S3 "
        "bucket in the Athena region, then rebuild r-code:latest."
    )


class AthenaConfigTests(unittest.TestCase):
    def test_region_prefers_aws_region_over_secrets(self):
        self.assertEqual(
            resolve_athena_region("us-east-1", env={"AWS_REGION": "eu-central-1"}),
            "eu-central-1",
        )

    def test_region_falls_back_to_secrets_then_frankfurt(self):
        self.assertEqual(resolve_athena_region("eu-west-1", env={}), "eu-west-1")
        self.assertEqual(resolve_athena_region(None, env={}), "eu-central-1")

    def test_skips_katrin_test_and_uses_data_lake(self):
        uri = resolve_athena_s3_staging_dir(
            "powerbi_old",
            env={
                "s3_staging_dir": "s3://katrin-test/",
                "s3_data_lake_bucket": "lecturio-datalake",
                "AWS_REGION": "eu-central-1",
            },
        )
        self.assertEqual(uri, "s3://lecturio-datalake/athena-query-results/powerbi_old/")

    def test_skips_katrin_test_without_scheme(self):
        uri = resolve_athena_s3_staging_dir(
            "powerbi",
            env={
                "s3_staging_dir": "katrin-test",
                "s3_to_redshift_bucket": "lecturio-redshift-staging",
            },
        )
        self.assertEqual(uri, "s3://lecturio-redshift-staging/athena-query-results/powerbi/")

    def test_uses_explicit_staging_dir_when_valid(self):
        uri = resolve_athena_s3_staging_dir(
            "powerbi_old",
            explicit="s3://company-athena-results/queries",
            env={"s3_staging_dir": "s3://katrin-test/"},
        )
        self.assertEqual(uri, "s3://company-athena-results/queries/powerbi_old/")

    def test_keeps_existing_db_suffix(self):
        uri = resolve_athena_s3_staging_dir(
            "powerbi_old",
            env={"s3_staging_dir": "s3://company-athena-results/powerbi_old/"},
        )
        self.assertEqual(uri, "s3://company-athena-results/powerbi_old/")

    def test_errors_when_only_katrin_test_is_configured(self):
        with self.assertRaises(ValueError) as ctx:
            resolve_athena_s3_staging_dir(
                "powerbi",
                env={"s3_staging_dir": "s3://katrin-test/"},
            )
        message = str(ctx.exception)
        self.assertIn("katrin-test", message)
        self.assertIn("s3_data_lake_bucket", message)

    def test_extracts_bucket_name_from_uri(self):
        self.assertEqual(extract_s3_bucket("s3://katrin-test/powerbi_old/"), "katrin-test")
        self.assertEqual(extract_s3_bucket("katrin-test"), "katrin-test")


if __name__ == "__main__":
    unittest.main()
