"""Spec tests for Athena region / staging-dir resolution.

Mirrors src/common/R/athena_config.R so we can verify the rules without R.
"""

from __future__ import annotations

import unittest


ATHENA_REGION_DEFAULT = "eu-central-1"
KATRIN_RESULTS_BUCKET = "katrin-test"
KATRIN_RESULTS_PREFIX = "athena-results"
KATRIN_RESULTS_URI = "s3://katrin-test/athena-results/"
CUBE_RESULTS_URI = "s3://cube-athena-query-results-dev/"


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


def extract_s3_key(uri: str) -> str:
    if not uri:
        return ""
    path = uri.strip()
    if path.lower().startswith("s3://"):
        path = path[5:]
    if "/" not in path:
        return ""
    return path.split("/", 1)[1]


def normalize_s3_uri(value: str, db: str | None = None) -> str:
    if value is None or not str(value).strip():
        return ""
    uri = str(value).strip()
    if not uri.lower().startswith("s3://"):
        uri = f"s3://{uri}"
    uri = "s3://" + uri[5:]
    if not uri.endswith("/"):
        uri += "/"
    if db and not uri.endswith(f"{db}/"):
        uri += f"{db}/"
    return uri


def ensure_allowed_athena_prefix(uri: str, db: str | None = None) -> str:
    if not uri or not str(uri).strip():
        return ""
    bucket = extract_s3_bucket(uri).lower()
    if bucket != KATRIN_RESULTS_BUCKET:
        return normalize_s3_uri(uri, db=db)
    key = extract_s3_key(uri)
    if not (key == KATRIN_RESULTS_PREFIX or key.startswith(f"{KATRIN_RESULTS_PREFIX}/")):
        uri = KATRIN_RESULTS_URI
    return normalize_s3_uri(uri, db=db)


def resolve_athena_region(
    secret_region: str | None = None,
    env: dict[str, str] | None = None,
    staging_uri: str | None = None,
) -> str:
    secret_value = (secret_region or "").strip()
    candidates = [
        get_env_value("AWS_REGION", env),
        get_env_value("AWS_DEFAULT_REGION", env),
        secret_value,
        ATHENA_REGION_DEFAULT,
    ]
    region = next(value for value in candidates if value)
    if extract_s3_bucket(staging_uri or "").lower() == KATRIN_RESULTS_BUCKET:
        if region != ATHENA_REGION_DEFAULT:
            return ATHENA_REGION_DEFAULT
    return region


def staging_candidates(explicit: str | None = None, env: dict[str, str] | None = None):
    return [
        (explicit or "").strip(),
        get_env_value("AWS_ATHENA_S3_STAGING_DIR", env),
        get_env_value("s3_staging_dir", env),
        get_env_value("athena_s3_output_bucket", env),
        KATRIN_RESULTS_URI,
        CUBE_RESULTS_URI,
    ]


def resolve_athena_s3_staging_dir(
    db: str,
    explicit: str | None = None,
    env: dict[str, str] | None = None,
) -> str:
    for raw in staging_candidates(explicit=explicit, env=env):
        if not raw:
            continue
        uri = ensure_allowed_athena_prefix(raw, db=db)
        if uri:
            return uri
    raise ValueError(
        "No Athena query-results location configured. "
        "Set s3_staging_dir=s3://katrin-test/athena-results/ in .Renviron, "
        "then rebuild r-code:latest."
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

    def test_katrin_test_forces_frankfurt_even_if_secrets_say_otherwise(self):
        self.assertEqual(
            resolve_athena_region(
                "us-east-1",
                env={},
                staging_uri="s3://katrin-test/athena-results/powerbi_old/",
            ),
            "eu-central-1",
        )

    def test_rewrites_katrin_bucket_root_to_iam_prefix(self):
        uri = resolve_athena_s3_staging_dir(
            "powerbi_old",
            env={"s3_staging_dir": "s3://katrin-test/"},
        )
        self.assertEqual(uri, "s3://katrin-test/athena-results/powerbi_old/")

    def test_rewrites_katrin_bucket_name_only(self):
        uri = resolve_athena_s3_staging_dir(
            "powerbi",
            env={"s3_staging_dir": "katrin-test"},
        )
        self.assertEqual(uri, "s3://katrin-test/athena-results/powerbi/")

    def test_rewrites_old_helper_db_suffix_outside_iam_prefix(self):
        uri = resolve_athena_s3_staging_dir(
            "powerbi_old",
            env={"s3_staging_dir": "s3://katrin-test/powerbi_old/"},
        )
        self.assertEqual(uri, "s3://katrin-test/athena-results/powerbi_old/")

    def test_keeps_existing_athena_results_prefix(self):
        uri = resolve_athena_s3_staging_dir(
            "powerbi_old",
            env={"s3_staging_dir": "s3://katrin-test/athena-results/"},
        )
        self.assertEqual(uri, "s3://katrin-test/athena-results/powerbi_old/")

    def test_defaults_to_katrin_athena_results_when_unset(self):
        self.assertEqual(
            resolve_athena_s3_staging_dir("powerbi_old", env={}),
            "s3://katrin-test/athena-results/powerbi_old/",
        )

    def test_uses_explicit_non_katrin_staging_dir(self):
        uri = resolve_athena_s3_staging_dir(
            "powerbi_old",
            explicit="s3://cube-athena-query-results-dev/queries",
            env={"s3_staging_dir": "s3://katrin-test/"},
        )
        self.assertEqual(uri, "s3://cube-athena-query-results-dev/queries/powerbi_old/")

    def test_extracts_bucket_and_key(self):
        self.assertEqual(extract_s3_bucket("s3://katrin-test/athena-results/"), "katrin-test")
        self.assertEqual(extract_s3_key("s3://katrin-test/athena-results/"), "athena-results/")
        self.assertEqual(extract_s3_key("katrin-test"), "")


if __name__ == "__main__":
    unittest.main()
