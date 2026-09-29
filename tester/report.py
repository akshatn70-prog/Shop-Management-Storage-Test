from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any


@dataclass
class TestResult:
    name: str
    status: str
    expected: str
    actual: str
    duration_ms: int
    screenshot: str | None = None
    error: str | None = None


@dataclass
class RunReport:
    run_id: str
    started_at: str
    finished_at: str
    duration_ms: int
    status: str
    tests: list[TestResult] = field(default_factory=list)
    report_txt: str | None = None
    report_json: str | None = None

    @property
    def passed(self) -> int:
        return sum(test.status == "PASS" for test in self.tests)

    @property
    def failed(self) -> int:
        return sum(test.status == "FAIL" for test in self.tests)

    @property
    def blocked(self) -> int:
        return sum(test.status == "BLOCKED" for test in self.tests)

    def telegram_summary(self) -> str:
        lines = [
            f"Run: {self.run_id}",
            f"Status: {self.status}",
            f"Total tests: {len(self.tests)}",
            f"Passed: {self.passed} | Failed: {self.failed} | Blocked: {self.blocked}",
            f"Duration: {self.duration_ms / 1000:.1f}s",
        ]
        issues = [test for test in self.tests if test.status in {"FAIL", "BLOCKED"}]
        if issues:
            lines.append("Issues:")
            lines.extend(f"- {test.name}: {(test.error or test.actual)[:240]}" for test in issues)
        return "\n".join(lines)


def create_report(
    run_id: str,
    started_at: datetime,
    finished_at: datetime,
    tests: list[TestResult],
    report_dir: Path,
) -> RunReport:
    report_dir.mkdir(parents=True, exist_ok=True)
    duration_ms = int((finished_at - started_at).total_seconds() * 1000)
    status = "PASS" if all(test.status == "PASS" for test in tests) else (
        "FAIL" if any(test.status == "FAIL" for test in tests) else "BLOCKED"
    )
    report = RunReport(
        run_id=run_id,
        started_at=started_at.isoformat(timespec="seconds"),
        finished_at=finished_at.isoformat(timespec="seconds"),
        duration_ms=duration_ms,
        status=status,
        tests=tests,
    )
    txt_path = report_dir / f"run-{run_id}.txt"
    json_path = report_dir / f"run-{run_id}.json"
    txt_path.write_text(_render_text(report), encoding="utf-8")
    json_path.write_text(
        json.dumps(_json_payload(report), indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    report.report_txt = str(txt_path)
    report.report_json = str(json_path)
    return report


def _json_payload(report: RunReport) -> dict[str, Any]:
    return {
        "run_id": report.run_id,
        "started_at": report.started_at,
        "finished_at": report.finished_at,
        "duration_ms": report.duration_ms,
        "status": report.status,
        "summary": {
            "total": len(report.tests),
            "passed": report.passed,
            "failed": report.failed,
            "blocked": report.blocked,
        },
        "tests": [asdict(test) for test in report.tests],
    }


def _render_text(report: RunReport) -> str:
    lines = [
        f"Shop Management UI Test Run: {report.run_id}",
        f"Status: {report.status}",
        f"Started: {report.started_at}",
        f"Finished: {report.finished_at}",
        f"Duration: {report.duration_ms / 1000:.1f}s",
        f"Total: {len(report.tests)} | Passed: {report.passed} | Failed: {report.failed} | Blocked: {report.blocked}",
        "",
    ]
    for test in report.tests:
        lines.extend([
            f"[{test.status}] {test.name}",
            f"  Expected: {test.expected}",
            f"  Actual: {test.actual}",
        ])
        if test.error:
            lines.append(f"  Reason: {test.error}")
        if test.screenshot:
            lines.append(f"  Screenshot: {test.screenshot}")
        lines.append("")
    return "\n".join(lines)
