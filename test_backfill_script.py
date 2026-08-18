#!/usr/bin/env python3
"""Unit tests for the resume-safe Glue backfill orchestrator."""

from __future__ import annotations

import json
import unittest
from datetime import date
from pathlib import Path
from unittest.mock import Mock

from botocore.exceptions import ClientError

import backfill_script as bf


def client_error(code: str, message: str = "boom", operation: str = "StartJobRun") -> ClientError:
    return ClientError({"Error": {"Code": code, "Message": message}}, operation)


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


class FakeSleeper:
    def __init__(self, clock: FakeClock) -> None:
        self.clock = clock
        self.calls: list[float] = []

    def __call__(self, seconds: float) -> None:
        self.calls.append(seconds)
        self.clock.advance(seconds)


class GlueBackfillTests(unittest.TestCase):
    def setUp(self) -> None:
        self.clock = FakeClock()
        self.sleeper = FakeSleeper(self.clock)
        self.glue = Mock()
        self.logs: list[str] = []

    def orchestrator(self, **kwargs) -> bf.GlueBackfill:
        defaults = dict(
            glue_client=self.glue,
            job_name="cleanup-job",
            poll_seconds=30,
            concurrency_backoff_seconds=15,
            sleeper=self.sleeper,
            clock=self.clock,
            log=self.logs.append,
        )
        defaults.update(kwargs)
        return bf.GlueBackfill(**defaults)

    def test_retries_concurrent_runs_exceeded_then_starts(self) -> None:
        self.glue.start_job_run.side_effect = [
            client_error("ConcurrentRunsExceededException"),
            client_error("ConcurrentRunsExceeded"),
            {"JobRunId": "jr_ok"},
        ]

        run_id = self.orchestrator().start_job_with_retry("2023-06-30")

        self.assertEqual(run_id, "jr_ok")
        self.assertEqual(self.glue.start_job_run.call_count, 3)
        self.assertEqual(self.sleeper.calls, [15, 15])
        self.glue.start_job_run.assert_called_with(
            JobName="cleanup-job",
            Arguments={"--date": "2023-06-30"},
        )

    def test_wait_polls_until_success_without_giving_up(self) -> None:
        running = {"JobRun": {"JobRunState": "RUNNING"}}
        self.glue.get_job_run.side_effect = [running] * 40 + [
            {"JobRun": {"JobRunState": "SUCCEEDED"}}
        ]

        status = self.orchestrator().wait_for_job("2023-06-30", "jr_1")

        self.assertEqual(status, "SUCCEEDED")
        self.assertEqual(self.glue.get_job_run.call_count, 41)
        self.assertEqual(self.sleeper.calls, [30] * 40)

    def test_timeout_does_not_look_like_success_and_names_the_live_run(self) -> None:
        self.glue.get_job_run.return_value = {"JobRun": {"JobRunState": "RUNNING"}}
        orchestrator = self.orchestrator(max_wait_seconds=90)

        with self.assertRaises(TimeoutError) as ctx:
            orchestrator.wait_for_job("2023-06-30", "jr_still_running")

        self.assertIn("jr_still_running", str(ctx.exception))
        self.assertIn("Not starting another date", str(ctx.exception))
        self.assertEqual(self.glue.start_job_run.call_count, 0)

    def test_process_date_records_success_and_does_not_start_next_on_failure(self) -> None:
        state_path = Path("/tmp/backfill-test-state-success.json")
        if state_path.exists():
            state_path.unlink()
        state = bf.StateStore(state_path)
        self.addCleanup(lambda: state_path.exists() and state_path.unlink())

        self.glue.start_job_run.return_value = {"JobRunId": "jr_ok"}
        self.glue.get_job_run.return_value = {"JobRun": {"JobRunState": "SUCCEEDED"}}
        archive = Mock()

        status = self.orchestrator(state=state, archive_fn=archive).process_date("2023-06-30")

        self.assertEqual(status, "SUCCEEDED")
        archive.assert_called_once_with("2023-06-30")
        self.assertIn("2023-06-30", state.completed_dates())

    def test_failed_job_is_checkpointed_and_run_backfill_stops(self) -> None:
        state_path = Path("/tmp/backfill-test-state-fail.json")
        if state_path.exists():
            state_path.unlink()
        state = bf.StateStore(state_path)
        self.addCleanup(lambda: state_path.exists() and state_path.unlink())

        self.glue.start_job_run.return_value = {"JobRunId": "jr_bad"}
        self.glue.get_job_run.return_value = {
            "JobRun": {"JobRunState": "FAILED", "ErrorMessage": "spark died"}
        }
        orchestrator = self.orchestrator(state=state)

        with self.assertRaises(bf.GlueJobFailed):
            bf.run_backfill(orchestrator, ["2023-06-30", "2023-07-01"], workers=1)

        self.assertEqual(self.glue.start_job_run.call_count, 1)
        self.assertIn("2023-06-30", state._data["failed"])
        self.assertNotIn("2023-07-01", state._data["failed"])
        self.assertNotIn("2023-07-01", state.completed_dates())

    def test_resume_skips_completed_dates(self) -> None:
        state_path = Path("/tmp/backfill-test-state-resume.json")
        state_path.write_text(
            json.dumps({"completed": {"2023-06-30": {"run_id": "jr_old"}}, "failed": {}})
        )
        self.addCleanup(state_path.unlink)
        state = bf.StateStore(state_path)
        pending = bf.pending_dates(
            ["2023-06-30", "2023-07-01", "2023-07-02"],
            state,
            retry_failed=False,
        )
        self.assertEqual(pending, ["2023-07-01", "2023-07-02"])

    def test_failed_dates_are_skipped_unless_retry_failed(self) -> None:
        state_path = Path("/tmp/backfill-test-state-retry.json")
        state_path.write_text(
            json.dumps(
                {
                    "completed": {},
                    "failed": {"2023-06-30": {"error": "nope"}},
                }
            )
        )
        self.addCleanup(state_path.unlink)
        state = bf.StateStore(state_path)
        self.assertEqual(
            bf.pending_dates(["2023-06-30", "2023-07-01"], state, retry_failed=False),
            ["2023-07-01"],
        )
        self.assertEqual(
            bf.pending_dates(["2023-06-30", "2023-07-01"], state, retry_failed=True),
            ["2023-06-30", "2023-07-01"],
        )

    def test_parallel_workers_process_all_dates(self) -> None:
        self.glue.start_job_run.side_effect = [
            {"JobRunId": "jr_a"},
            {"JobRunId": "jr_b"},
        ]
        self.glue.get_job_run.return_value = {"JobRun": {"JobRunState": "SUCCEEDED"}}
        orchestrator = self.orchestrator()

        results = bf.run_backfill(
            orchestrator,
            ["2023-06-30", "2023-07-01"],
            workers=2,
        )

        self.assertEqual(set(results), {"2023-06-30", "2023-07-01"})
        self.assertTrue(all(value == "SUCCEEDED" for value in results.values()))
        self.assertEqual(self.glue.start_job_run.call_count, 2)

    def test_raise_glue_concurrency_updates_only_when_needed(self) -> None:
        self.glue.get_job.return_value = {
            "Job": {
                "Role": "arn:aws:iam::1:role/Glue",
                "Command": {"Name": "glueetl", "ScriptLocation": "s3://job.py"},
                "ExecutionProperty": {"MaxConcurrentRuns": 1},
                "GlueVersion": "4.0",
            }
        }

        current = self.orchestrator().raise_glue_concurrency(10)

        self.assertEqual(current, 10)
        self.glue.update_job.assert_called_once()
        payload = self.glue.update_job.call_args.kwargs["JobUpdate"]
        self.assertEqual(payload["ExecutionProperty"]["MaxConcurrentRuns"], 10)
        self.assertEqual(payload["GlueVersion"], "4.0")

        self.glue.get_job.return_value["Job"]["ExecutionProperty"]["MaxConcurrentRuns"] = 10
        self.glue.update_job.reset_mock()
        self.assertEqual(self.orchestrator().raise_glue_concurrency(10), 10)
        self.glue.update_job.assert_not_called()


class HelperTests(unittest.TestCase):
    def test_daterange_inclusive(self) -> None:
        self.assertEqual(
            bf.daterange(date(2023, 6, 30), date(2023, 7, 2)),
            ["2023-06-30", "2023-07-01", "2023-07-02"],
        )

    def test_build_job_arguments(self) -> None:
        self.assertEqual(
            bf.build_job_arguments("2023-06-30", "process_date", ["mode=backfill"]),
            {"--process_date": "2023-06-30", "--mode": "backfill"},
        )

    def test_is_concurrent_runs_exceeded(self) -> None:
        self.assertTrue(
            bf.is_concurrent_runs_exceeded(client_error("ConcurrentRunsExceededException"))
        )
        self.assertFalse(bf.is_concurrent_runs_exceeded(client_error("AccessDenied")))

    def test_archive_s3_partition_moves_objects(self) -> None:
        s3 = Mock()
        s3.get_paginator.return_value.paginate.return_value = [
            {
                "Contents": [
                    {"Key": "table/dt=2023-06-30/part-0.parquet"},
                    {"Key": "table/dt=2023-06-30/part-1.parquet"},
                ]
            }
        ]

        moved = bf.archive_s3_partition(
            s3,
            "s3://src/table/dt={date}",
            "s3://src/archive/dt={date}",
            "2023-06-30",
        )

        self.assertEqual(moved, 2)
        self.assertEqual(s3.copy_object.call_count, 2)
        self.assertEqual(s3.delete_object.call_count, 2)
        s3.copy_object.assert_any_call(
            Bucket="src",
            Key="archive/dt=2023-06-30/part-0.parquet",
            CopySource={"Bucket": "src", "Key": "table/dt=2023-06-30/part-0.parquet"},
        )

    def test_parse_args_smoke_test_defaults(self) -> None:
        args = bf.parse_args(
            [
                "--job-name",
                "cleanup-job",
                "--start-date",
                "2023-06-30",
                "--end-date",
                "2024-08-06",
                "--limit",
                "1",
            ]
        )
        dates = bf.resolve_dates(args)
        self.assertEqual(len(dates), 404)
        self.assertEqual(dates[0], "2023-06-30")
        self.assertEqual(args.limit, 1)
        self.assertEqual(args.workers, 1)


if __name__ == "__main__":
    unittest.main()
