#!/usr/bin/env python3
"""Resume-safe AWS Glue backfill orchestrator.

Replaces a one-date-at-a-time loop that crashes with ConcurrentRunsExceeded
when a poll timeout gives up and the previous Glue run is still active.

Why the old loop failed
-----------------------
The previous script started 2023-06-30, polled ~23 times (~11.5 minutes),
then moved on. Glue was still running that date (max concurrency = 1), so
StartJobRun for the next date raised ConcurrentRunsExceededException and
the process died. The 404-date run never got a chance to finish.

What this script does instead
-----------------------------
1. Smoke-test one date first (`--limit 1`) so you know the job works
   before launching the remaining hundreds of days.
2. Never abandon a run. Poll until SUCCEEDED / FAILED / TIMEOUT / STOPPED.
3. Treat ConcurrentRunsExceeded as backpressure: wait and retry, do not crash.
4. Checkpoint every success to a JSON state file and skip those dates on
   restart (`--state-file`).
5. Optionally run several dates at once (`--workers N`) after you raise
   Glue Maximum concurrency to at least N (`--raise-glue-concurrency N`).

Copy this file onto the Hetzner host (or run it anywhere with boto3 + AWS
creds) and invoke it from the same venv you already use:

    python3 -u backfill_script.py \\
        --job-name YOUR_GLUE_JOB \\
        --start-date 2023-06-30 \\
        --end-date 2024-08-06 \\
        --limit 1

When that single date succeeds, drop `--limit 1` and add workers if the
Glue job is safe to run on isolated date partitions:

    python3 -u backfill_script.py \\
        --job-name YOUR_GLUE_JOB \\
        --start-date 2023-06-30 \\
        --end-date 2024-08-06 \\
        --workers 10 \\
        --raise-glue-concurrency 10
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterable

try:
    import boto3
    from botocore.exceptions import ClientError
except ImportError as exc:  # pragma: no cover - import guard
    raise SystemExit(
        "boto3 is required. Install it in the same venv you use for the backfill "
        "(pip install boto3)."
    ) from exc


TERMINAL_SUCCESS = {"SUCCEEDED"}
TERMINAL_FAILURE = {"FAILED", "ERROR", "TIMEOUT", "STOPPED"}
IN_FLIGHT = {"STARTING", "RUNNING", "STOPPING", "WAITING"}

DEFAULT_POLL_SECONDS = 30
DEFAULT_CONCURRENCY_BACKOFF_SECONDS = 30


class GlueJobFailed(RuntimeError):
    """Raised when a Glue run reaches a terminal failure state."""


class StateStore:
    """JSON checkpoint of completed / failed dates so a restart can resume."""

    def __init__(self, path: Path):
        self.path = path
        self._lock = threading.Lock()
        self._data = {"completed": {}, "failed": {}}
        if path.exists():
            loaded = json.loads(path.read_text())
            self._data["completed"] = dict(loaded.get("completed") or {})
            self._data["failed"] = dict(loaded.get("failed") or {})

    def completed_dates(self) -> set[str]:
        with self._lock:
            return set(self._data["completed"])

    def failed_dates(self) -> set[str]:
        with self._lock:
            return set(self._data["failed"])

    def record_success(self, day: str, run_id: str) -> None:
        with self._lock:
            self._data["completed"][day] = {
                "run_id": run_id,
                "finished_at": datetime.now(timezone.utc).isoformat(),
            }
            self._data["failed"].pop(day, None)
            self._write()

    def record_failure(self, day: str, run_id: str | None, error: str) -> None:
        with self._lock:
            self._data["failed"][day] = {
                "run_id": run_id,
                "error": error,
                "finished_at": datetime.now(timezone.utc).isoformat(),
            }
            self._write()

    def _write(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(self.path.suffix + ".tmp")
        tmp.write_text(json.dumps(self._data, indent=2, sort_keys=True) + "\n")
        tmp.replace(self.path)


def daterange(start: date, end: date) -> list[str]:
    if end < start:
        raise ValueError(f"end date {end} is before start date {start}")
    days = []
    current = start
    while current <= end:
        days.append(current.isoformat())
        current += timedelta(days=1)
    return days


def load_dates_file(path: Path) -> list[str]:
    dates = []
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        date.fromisoformat(line)
        dates.append(line)
    return dates


def is_concurrent_runs_exceeded(error: ClientError) -> bool:
    code = error.response.get("Error", {}).get("Code", "")
    return code in {"ConcurrentRunsExceededException", "ConcurrentRunsExceeded"}


def build_job_arguments(day: str, date_arg_name: str, extra_args: list[str]) -> dict[str, str]:
    arguments = {f"--{date_arg_name}": day}
    for item in extra_args:
        if "=" not in item:
            raise ValueError(
                f"Extra Glue argument {item!r} must look like NAME=value "
                "(the leading -- is added automatically)."
            )
        key, value = item.split("=", 1)
        arguments[f"--{key.lstrip('-')}"] = value
    return arguments


def archive_s3_partition(
    s3_client: Any,
    source_prefix: str,
    dest_prefix: str,
    day: str,
) -> int:
    """Move every object under source to dest. Returns objects moved."""
    source = source_prefix.format(date=day).rstrip("/") + "/"
    dest = dest_prefix.format(date=day).rstrip("/") + "/"
    src_bucket, src_key = _split_s3_uri(source)
    dest_bucket, dest_key = _split_s3_uri(dest)

    moved = 0
    paginator = s3_client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=src_bucket, Prefix=src_key):
        for obj in page.get("Contents") or []:
            key = obj["Key"]
            suffix = key[len(src_key) :]
            s3_client.copy_object(
                Bucket=dest_bucket,
                Key=dest_key + suffix,
                CopySource={"Bucket": src_bucket, "Key": key},
            )
            s3_client.delete_object(Bucket=src_bucket, Key=key)
            moved += 1
    return moved


def _split_s3_uri(uri: str) -> tuple[str, str]:
    if not uri.startswith("s3://"):
        raise ValueError(f"S3 URI must start with s3://, got {uri!r}")
    rest = uri[len("s3://") :]
    bucket, _, key = rest.partition("/")
    if not bucket:
        raise ValueError(f"S3 URI is missing a bucket: {uri!r}")
    return bucket, key


class GlueBackfill:
    def __init__(
        self,
        glue_client: Any,
        job_name: str,
        *,
        poll_seconds: int = DEFAULT_POLL_SECONDS,
        concurrency_backoff_seconds: int = DEFAULT_CONCURRENCY_BACKOFF_SECONDS,
        date_arg_name: str = "date",
        extra_args: list[str] | None = None,
        state: StateStore | None = None,
        sleeper: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic,
        archive_fn: Callable[[str], None] | None = None,
        log: Callable[[str], None] = print,
        max_wait_seconds: float | None = None,
    ):
        self.glue = glue_client
        self.job_name = job_name
        self.poll_seconds = poll_seconds
        self.concurrency_backoff_seconds = concurrency_backoff_seconds
        self.date_arg_name = date_arg_name
        self.extra_args = extra_args or []
        self.state = state
        self.sleeper = sleeper
        self.clock = clock
        self.archive_fn = archive_fn
        self.log = log
        self.max_wait_seconds = max_wait_seconds

    def start_job_with_retry(self, day: str) -> str:
        arguments = build_job_arguments(day, self.date_arg_name, self.extra_args)
        while True:
            try:
                response = self.glue.start_job_run(
                    JobName=self.job_name,
                    Arguments=arguments,
                )
            except ClientError as error:
                if is_concurrent_runs_exceeded(error):
                    self.log(
                        "Concurrent runs exceeded while starting "
                        f"{day}. Waiting {self.concurrency_backoff_seconds}s "
                        "for a Glue slot..."
                    )
                    self.sleeper(self.concurrency_backoff_seconds)
                    continue
                raise
            run_id = response["JobRunId"]
            self.log(f"Started Glue Job for {day}. Run ID: {run_id}")
            return run_id

    def wait_for_job(self, day: str, run_id: str) -> str:
        started = self.clock()
        while True:
            response = self.glue.get_job_run(JobName=self.job_name, RunId=run_id)
            status = response["JobRun"]["JobRunState"]
            if status in TERMINAL_SUCCESS:
                self.log(f"Job succeeded for {day}.")
                return status
            if status in TERMINAL_FAILURE:
                error = response["JobRun"].get("ErrorMessage") or status
                raise GlueJobFailed(
                    f"Glue job for {day} ended with {status}: {error}"
                )
            if (
                self.max_wait_seconds is not None
                and self.clock() - started >= self.max_wait_seconds
            ):
                # Still do not start the next date. Surface the hang so an
                # operator can inspect the live run instead of colliding.
                raise TimeoutError(
                    f"Glue job for {day} ({run_id}) still {status} after "
                    f"{self.max_wait_seconds:.0f}s. Not starting another date."
                )
            self.log(
                f"Job status is {status} for {day}. "
                f"Waiting {self.poll_seconds} seconds..."
            )
            self.sleeper(self.poll_seconds)

    def process_date(self, day: str) -> str:
        self.log(f"\n--- Processing Date: {day} ---")
        if self.archive_fn is not None:
            self.archive_fn(day)
            self.log(f"Successfully archived partition: {day}")
        run_id = self.start_job_with_retry(day)
        try:
            status = self.wait_for_job(day, run_id)
        except Exception as error:
            if self.state is not None:
                self.state.record_failure(day, run_id, str(error))
            raise
        if self.state is not None:
            self.state.record_success(day, run_id)
        return status

    def raise_glue_concurrency(self, max_concurrent: int) -> int:
        job = self.glue.get_job(JobName=self.job_name)["Job"]
        current = int(job.get("ExecutionProperty", {}).get("MaxConcurrentRuns") or 1)
        if current >= max_concurrent:
            self.log(
                f"Glue Maximum concurrency is already {current} "
                f"(requested {max_concurrent})."
            )
            return current
        update = _job_update_payload(job)
        update["ExecutionProperty"] = {"MaxConcurrentRuns": max_concurrent}
        self.glue.update_job(JobName=self.job_name, JobUpdate=update)
        self.log(
            f"Raised Glue Maximum concurrency from {current} to {max_concurrent}."
        )
        return max_concurrent


def _job_update_payload(job: dict[str, Any]) -> dict[str, Any]:
    update: dict[str, Any] = {
        "Role": job["Role"],
        "Command": job["Command"],
    }
    optional = (
        "DefaultArguments",
        "NonOverridableArguments",
        "Description",
        "LogUri",
        "MaxRetries",
        "AllocatedCapacity",
        "Timeout",
        "WorkerType",
        "NumberOfWorkers",
        "SecurityConfiguration",
        "NotificationProperty",
        "GlueVersion",
        "Connections",
        "ExecutionClass",
        "SourceControlDetails",
        "JobMode",
        "MaintenanceWindow",
        "MaxCapacity",
    )
    for key in optional:
        if key in job:
            update[key] = job[key]
    return update


def pending_dates(dates: Iterable[str], state: StateStore | None, retry_failed: bool) -> list[str]:
    completed = state.completed_dates() if state is not None else set()
    pending = []
    for day in dates:
        if day in completed:
            continue
        if state is not None and day in state.failed_dates() and not retry_failed:
            continue
        pending.append(day)
    return pending


def run_backfill(
    orchestrator: GlueBackfill,
    dates: list[str],
    *,
    workers: int = 1,
    stop_on_failure: bool = True,
) -> dict[str, str]:
    results: dict[str, str] = {}
    if workers < 1:
        raise ValueError("workers must be >= 1")
    if workers == 1:
        for day in dates:
            try:
                results[day] = orchestrator.process_date(day)
            except Exception as error:
                results[day] = f"FAILED: {error}"
                if stop_on_failure:
                    raise
        return results

    errors: list[BaseException] = []
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(orchestrator.process_date, day): day for day in dates}
        for future in as_completed(futures):
            day = futures[future]
            try:
                results[day] = future.result()
            except Exception as error:  # noqa: BLE001 - recorded per date
                results[day] = f"FAILED: {error}"
                errors.append(error)
                if stop_on_failure:
                    for remaining in futures:
                        remaining.cancel()
                    raise
    if errors and stop_on_failure:
        raise errors[0]
    return results


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Resume-safe Glue backfill that retries ConcurrentRunsExceeded."
    )
    parser.add_argument("--job-name", required=True, help="Glue job name")
    parser.add_argument("--region", default="eu-central-1")
    parser.add_argument("--start-date", help="Inclusive YYYY-MM-DD")
    parser.add_argument("--end-date", help="Inclusive YYYY-MM-DD")
    parser.add_argument("--dates-file", type=Path, help="File with one YYYY-MM-DD per line")
    parser.add_argument(
        "--limit",
        type=int,
        help="Process only the first N pending dates (use 1 as a smoke test)",
    )
    parser.add_argument("--date-arg-name", default="date", help="Glue argument name for the date")
    parser.add_argument(
        "--job-arg",
        action="append",
        default=[],
        dest="job_args",
        help="Extra Glue argument NAME=value (repeatable)",
    )
    parser.add_argument("--workers", type=int, default=1, help="Parallel dates to run")
    parser.add_argument(
        "--raise-glue-concurrency",
        type=int,
        metavar="N",
        help="Set the Glue job Maximum concurrency to N before starting",
    )
    parser.add_argument("--poll-seconds", type=int, default=DEFAULT_POLL_SECONDS)
    parser.add_argument(
        "--concurrency-backoff-seconds",
        type=int,
        default=DEFAULT_CONCURRENCY_BACKOFF_SECONDS,
    )
    parser.add_argument(
        "--state-file",
        type=Path,
        default=Path("backfill_state.json"),
        help="Checkpoint file used to resume after a crash",
    )
    parser.add_argument(
        "--retry-failed",
        action="store_true",
        help="Retry dates recorded as failed in the state file",
    )
    parser.add_argument(
        "--continue-on-failure",
        action="store_true",
        help="Keep remaining dates going if one Glue run fails",
    )
    parser.add_argument(
        "--archive-source-prefix",
        help="Optional s3://bucket/prefix/{date}/ to move aside before each run",
    )
    parser.add_argument(
        "--archive-dest-prefix",
        help="Optional s3://bucket/archive/{date}/ destination for archived objects",
    )
    return parser.parse_args(argv)


def resolve_dates(args: argparse.Namespace) -> list[str]:
    if args.dates_file:
        dates = load_dates_file(args.dates_file)
    elif args.start_date and args.end_date:
        dates = daterange(date.fromisoformat(args.start_date), date.fromisoformat(args.end_date))
    else:
        raise SystemExit("Provide --dates-file or both --start-date and --end-date.")
    return dates


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    dates = resolve_dates(args)
    state = StateStore(args.state_file)
    pending = pending_dates(dates, state, retry_failed=args.retry_failed)
    if args.limit is not None:
        pending = pending[: args.limit]

    print(f"Found {len(dates)} dates to process.")
    print(f"{len(state.completed_dates())} already completed in {args.state_file}.")
    print(f"{len(pending)} pending after resume/limit filters.")
    if not pending:
        print("Nothing to do.")
        return 0

    session = boto3.session.Session(region_name=args.region)
    glue = session.client("glue")

    archive_fn = None
    if args.archive_source_prefix or args.archive_dest_prefix:
        if not (args.archive_source_prefix and args.archive_dest_prefix):
            raise SystemExit("Provide both --archive-source-prefix and --archive-dest-prefix.")
        s3 = session.client("s3")

        def archive_fn(day: str, _s3=s3) -> None:
            moved = archive_s3_partition(
                _s3, args.archive_source_prefix, args.archive_dest_prefix, day
            )
            print(f"Archived {moved} object(s) for {day}.")

    orchestrator = GlueBackfill(
        glue,
        args.job_name,
        poll_seconds=args.poll_seconds,
        concurrency_backoff_seconds=args.concurrency_backoff_seconds,
        date_arg_name=args.date_arg_name,
        extra_args=args.job_args,
        state=state,
        archive_fn=archive_fn,
    )
    if args.raise_glue_concurrency:
        orchestrator.raise_glue_concurrency(args.raise_glue_concurrency)
        if args.workers > args.raise_glue_concurrency:
            print(
                f"Warning: --workers {args.workers} is higher than Glue "
                f"concurrency {args.raise_glue_concurrency}. Extra starts "
                "will wait for a slot."
            )

    run_backfill(
        orchestrator,
        pending,
        workers=args.workers,
        stop_on_failure=not args.continue_on_failure,
    )
    print("Backfill finished.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
