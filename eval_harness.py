#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import os
import statistics
import sys
import time
from dataclasses import dataclass
from datetime import datetime, UTC
from pathlib import Path
from typing import Any, Optional

import requests


DETECTION_ACTIONS = {"chase_player", "wake_guard", "block_exit"}
DETECTION_GUARD_MODES = {"chase_player", "block_exit"}
GUARD_RESPONSE_MODES = {"chase_player", "block_exit", "investigate_last_seen", "search_counter", "question_player"}


@dataclass
class Phase:
	duration_s: float
	observation_updates: dict[str, Any]
	world_events: list[dict[str, Any]]
	chat_choice: Optional[str] = None
	chat_message: Optional[str] = None
	mark_trigger: bool = False


@dataclass
class Scenario:
	scenario_id: str
	hood_on: bool
	ground_truth_thief: bool
	attempt_escape: bool
	phases: list[Phase]
	description: str


class APIClient:
	def __init__(self, base_url: str, timeout_s: float = 7.0):
		self.base_url = base_url.rstrip("/")
		self.timeout_s = timeout_s
		self.session = requests.Session()

	def post(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
		url = f"{self.base_url}{path}"
		resp = self.session.post(url, json=payload, timeout=self.timeout_s)
		resp.raise_for_status()
		return resp.json() if resp.text else {}

	def healthcheck(self) -> bool:
		try:
			self.post("/reset_brain", {})
			return True
		except Exception:
			return False


def _base_observation(hood_on: bool) -> dict[str, Any]:
	return {
		"hood_on": hood_on,
		"distance": 3.1,
		"los": True,
		"player_speed": 0.2,
		"near_key": False,
		"key_missing": False,
		"last_seen_pos": {"x": -0.4, "y": 0.94, "z": -2.9},
		"recent_actions": ["walk"],
		"interaction_active": False,
		"metadata": {"suspicion_hint": 12.0},
	}


def _with_seed_offset(value: float, seed_idx: int, low_delta: float, high_delta: float) -> float:
	return value + (low_delta if seed_idx == 0 else high_delta)


def build_scenarios() -> list[Scenario]:
	# 5 behavior profiles x 2 hood states x 2 seed variants = 20 scenarios.
	scenarios: list[Scenario] = []
	profiles = [
		"calm_browse",
		"look_around_leave",
		"risky_hover_key",
		"stealth_steal_escape",
		"rush_steal_escape",
	]
	for profile in profiles:
		for hood_on in (False, True):
			for seed_idx in (0, 1):
				scenarios.append(_make_scenario(profile, hood_on, seed_idx))
	return scenarios


def _make_scenario(profile: str, hood_on: bool, seed_idx: int) -> Scenario:
	variant = f"h{'on' if hood_on else 'off'}_v{seed_idx + 1}"
	scenario_id = f"{profile}__{variant}"
	chat_msg = "I am just looking around."
	look_message = "Tell Barnaby you are just having a look around first."
	seed_bump = 0.17 if seed_idx == 1 else 0.0
	speed_bump = 0.25 if seed_idx == 1 else 0.0

	if profile == "calm_browse":
		return Scenario(
			scenario_id=scenario_id,
			hood_on=hood_on,
			ground_truth_thief=False,
			attempt_escape=False,
			description="Innocent browsing baseline with no theft actions.",
			phases=[
				Phase(
					duration_s=0.9 + seed_bump,
					observation_updates={"distance": 3.4, "los": True, "player_speed": 0.1 + speed_bump, "recent_actions": ["walk", "charm"]},
					world_events=[{"event_type": "calm_interaction", "intensity": 1.0, "metadata": {"hood_on": hood_on}}],
					chat_choice="charm",
					chat_message=chat_msg,
				),
				Phase(
					duration_s=1.0 + seed_bump,
					observation_updates={"distance": 3.9, "los": False, "player_speed": 0.2 + speed_bump, "recent_actions": ["walk"]},
					world_events=[{"event_type": "player_unseen", "intensity": 0.9, "metadata": {}}],
				),
			],
		)

	if profile == "look_around_leave":
		return Scenario(
			scenario_id=scenario_id,
			hood_on=hood_on,
			ground_truth_thief=False,
			attempt_escape=False,
			description="Player requests to look around, but leaves without stealing.",
			phases=[
				Phase(
					duration_s=0.9 + seed_bump,
					observation_updates={"distance": 2.5, "los": True, "interaction_active": True, "recent_actions": ["choice_look_around"]},
					world_events=[],
					chat_choice="look_around",
					chat_message=look_message,
				),
				Phase(
					duration_s=1.1 + seed_bump,
					observation_updates={"distance": 2.9, "los": True, "near_key": False, "player_speed": 0.8 + speed_bump, "interaction_active": False, "recent_actions": ["walk"]},
					world_events=[{"event_type": "distract_started", "intensity": 1.0, "metadata": {"choice_id": "look_around"}}],
				),
				Phase(
					duration_s=0.9 + seed_bump,
					observation_updates={"distance": 4.0, "los": False, "near_key": False, "player_speed": 1.0 + speed_bump, "recent_actions": ["walk_away"]},
					world_events=[{"event_type": "distract_expired", "intensity": 1.0, "metadata": {}}],
				),
			],
		)

	if profile == "risky_hover_key":
		return Scenario(
			scenario_id=scenario_id,
			hood_on=hood_on,
			ground_truth_thief=False,
			attempt_escape=False,
			description="Suspicious movement near key with no theft attempt.",
			phases=[
				Phase(
					duration_s=0.8 + seed_bump,
					observation_updates={"distance": 2.2, "los": True, "player_speed": 1.9 + speed_bump, "near_key": True, "recent_actions": ["sprint", "near_key"]},
					world_events=[{"event_type": "player_seen", "intensity": _with_seed_offset(1.7, seed_idx, 0.0, 0.25), "metadata": {"near_key": True}}],
					mark_trigger=True,
				),
				Phase(
					duration_s=1.1 + seed_bump,
					observation_updates={"distance": 2.0, "los": True, "player_speed": 2.5 + speed_bump, "near_key": True, "recent_actions": ["sprint_to_key"]},
					world_events=[{"event_type": "attempt_key_without_distract", "intensity": _with_seed_offset(1.0, seed_idx, 0.0, 0.2), "metadata": {"hood_on": hood_on}}],
				),
				Phase(
					duration_s=0.8 + seed_bump,
					observation_updates={"distance": 3.6, "los": False, "player_speed": 1.4 + speed_bump, "near_key": False, "recent_actions": ["retreat"]},
					world_events=[{"event_type": "player_unseen", "intensity": 0.8, "metadata": {}}],
				),
			],
		)

	if profile == "stealth_steal_escape":
		return Scenario(
			scenario_id=scenario_id,
			hood_on=hood_on,
			ground_truth_thief=True,
			attempt_escape=True,
			description="Structured stealth flow: look around, steal key, exit.",
			phases=[
				Phase(
					duration_s=0.8 + seed_bump,
					observation_updates={"distance": 2.5, "los": True, "interaction_active": True, "player_speed": 0.1, "recent_actions": ["choice_look_around"]},
					world_events=[],
					chat_choice="look_around",
					chat_message=look_message,
				),
				Phase(
					duration_s=1.0 + seed_bump,
					observation_updates={"distance": 2.9, "los": False, "near_key": True, "player_speed": 1.0 + speed_bump, "interaction_active": False, "recent_actions": ["walk", "near_key"]},
					world_events=[{"event_type": "distract_started", "intensity": 1.0, "metadata": {"choice_id": "look_around"}}],
				),
				Phase(
					duration_s=0.7 + seed_bump,
					observation_updates={"distance": 2.1, "los": False, "near_key": True, "key_missing": True, "player_speed": 1.2 + speed_bump, "recent_actions": ["steal_key"]},
					world_events=[{"event_type": "key_touched", "intensity": 1.0, "metadata": {"hood_on": hood_on}}],
					mark_trigger=True,
				),
				Phase(
					duration_s=0.9 + seed_bump,
					observation_updates={"distance": 5.0, "los": False, "near_key": False, "key_missing": True, "player_speed": 2.8 + speed_bump, "recent_actions": ["run"]},
					world_events=[],
				),
			],
		)

	# rush_steal_escape
	return Scenario(
		scenario_id=scenario_id,
		hood_on=hood_on,
		ground_truth_thief=True,
		attempt_escape=True,
		description="Aggressive theft path with high visibility and speed.",
		phases=[
			Phase(
				duration_s=0.7 + seed_bump,
				observation_updates={"distance": 2.3, "los": True, "interaction_active": True, "player_speed": 0.2, "recent_actions": ["choice_pressure"]},
				world_events=[],
				chat_choice="pressure",
				chat_message="Lower your price. I do not have all day.",
			),
			Phase(
				duration_s=0.8 + seed_bump,
				observation_updates={"distance": 1.9, "los": True, "near_key": True, "player_speed": 3.6 + speed_bump, "interaction_active": False, "recent_actions": ["sprint", "near_key"]},
				world_events=[{"event_type": "player_seen", "intensity": _with_seed_offset(2.0, seed_idx, 0.0, 0.3), "metadata": {"near_key": True}}],
			),
			Phase(
				duration_s=0.7 + seed_bump,
				observation_updates={"distance": 1.7, "los": True, "near_key": True, "key_missing": True, "player_speed": 3.8 + speed_bump, "recent_actions": ["steal_key", "sprint_to_key"]},
				world_events=[{"event_type": "key_touched", "intensity": 1.2, "metadata": {"hood_on": hood_on}}],
				mark_trigger=True,
			),
			Phase(
				duration_s=0.9 + seed_bump,
				observation_updates={"distance": 4.4, "los": True, "near_key": False, "key_missing": True, "player_speed": 4.0 + speed_bump, "recent_actions": ["run"]},
				world_events=[],
			),
		],
	)


def _is_detection_from_decide(payload: dict[str, Any]) -> bool:
	action = str(payload.get("action", ""))
	intent = str(payload.get("intent", ""))
	confidence = float(payload.get("confidence", 0.0))
	guard_state = payload.get("guard_state", {})
	guard_mode = str(guard_state.get("mode", "")) if isinstance(guard_state, dict) else ""
	if action in DETECTION_ACTIONS:
		return True
	if guard_mode in DETECTION_GUARD_MODES:
		return True
	if intent == "accuse" and confidence >= 0.75:
		return True
	return False


def _is_guard_response(payload: dict[str, Any]) -> bool:
	guard_state = payload.get("guard_state", {})
	if not isinstance(guard_state, dict):
		return False
	mode = str(guard_state.get("mode", "idle"))
	return mode in GUARD_RESPONSE_MODES


def _utc_timestamp() -> str:
	return datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")


def run_scenario(
	client: APIClient,
	scenario: Scenario,
	tick_s: float,
	sleep_s: float,
) -> dict[str, Any]:
	start_monotonic = time.monotonic()
	client.post("/reset_brain", {})
	world_state = client.post("/world_event", {"event_type": "start_visit", "intensity": 1.0, "metadata": {"hood_on": scenario.hood_on}})

	observation = _base_observation(scenario.hood_on)
	detection_time_s: Optional[float] = None
	detection_reason = ""
	guard_response_time_s: Optional[float] = None
	trigger_time_s: Optional[float] = None
	decide_samples = 0
	final_decide: dict[str, Any] = {}
	final_run_outcome = str(world_state.get("brain_state", {}).get("run_outcome", "active"))
	final_suspicion = float(world_state.get("brain_state", {}).get("suspicion", 0.0))

	def now_s() -> float:
		return time.monotonic() - start_monotonic

	def mark_detection(reason: str):
		nonlocal detection_time_s, detection_reason
		if detection_time_s is None:
			detection_time_s = now_s()
			detection_reason = reason

	for phase in scenario.phases:
		observation.update(phase.observation_updates)
		for evt in phase.world_events:
			event_resp = client.post(
				"/world_event",
				{
					"event_type": evt["event_type"],
					"intensity": float(evt.get("intensity", 1.0)),
					"metadata": evt.get("metadata", {}),
				},
			)
			final_run_outcome = str(event_resp.get("brain_state", {}).get("run_outcome", final_run_outcome))
			final_suspicion = float(event_resp.get("brain_state", {}).get("suspicion", final_suspicion))
			action_hint = str(event_resp.get("action_hint", "idle"))
			if action_hint == "alert":
				mark_detection("world_event_alert")
			if phase.mark_trigger and trigger_time_s is None:
				trigger_time_s = now_s()

		if phase.chat_choice:
			chat_resp = client.post(
				"/chat",
				{
					"message": phase.chat_message or "",
					"choice_id": phase.chat_choice,
				},
			)
			final_run_outcome = str(chat_resp.get("brain_state", {}).get("run_outcome", final_run_outcome))
			final_suspicion = float(chat_resp.get("brain_state", {}).get("suspicion", final_suspicion))
			if bool(chat_resp.get("is_caught", False)):
				mark_detection("chat_caught")

		phase_end_at = time.monotonic() + phase.duration_s
		while time.monotonic() < phase_end_at:
			decide_resp = client.post("/decide", {"npc_id": "barnaby", "guard_id": "guard", "observation": observation})
			final_decide = decide_resp
			decide_samples += 1
			brain_state = decide_resp.get("brain_state", {})
			if isinstance(brain_state, dict):
				final_suspicion = float(brain_state.get("suspicion", final_suspicion))
				final_run_outcome = str(brain_state.get("run_outcome", final_run_outcome))
			if _is_detection_from_decide(decide_resp):
				mark_detection("decide_detection")
			if _is_guard_response(decide_resp) and guard_response_time_s is None:
				guard_response_time_s = now_s()

			if sleep_s > 0.0:
				time.sleep(sleep_s)
			if tick_s > sleep_s:
				time.sleep(tick_s - sleep_s)

	# Only issue exit_success if scenario still appears undetected.
	if scenario.attempt_escape:
		if detection_time_s is None:
			exit_resp = client.post("/world_event", {"event_type": "exit_success", "intensity": 1.0, "metadata": {"hood_on": scenario.hood_on}})
			final_run_outcome = str(exit_resp.get("brain_state", {}).get("run_outcome", final_run_outcome))
		else:
			fail_resp = client.post(
				"/world_event",
				{
					"event_type": "run_failed",
					"intensity": 1.0,
					"metadata": {"reason": "Detected before escape in evaluation harness."},
				},
			)
			final_run_outcome = str(fail_resp.get("brain_state", {}).get("run_outcome", final_run_outcome))

	false_accusation = (not scenario.ground_truth_thief) and (detection_time_s is not None)
	successful_escape = scenario.attempt_escape and detection_time_s is None and final_run_outcome == "success"

	guard_latency_s: Optional[float] = None
	if trigger_time_s is not None and guard_response_time_s is not None and guard_response_time_s >= trigger_time_s:
		guard_latency_s = round(guard_response_time_s - trigger_time_s, 3)

	return {
		"scenario_id": scenario.scenario_id,
		"description": scenario.description,
		"hood_on": scenario.hood_on,
		"ground_truth_thief": scenario.ground_truth_thief,
		"attempt_escape": scenario.attempt_escape,
		"detected": detection_time_s is not None,
		"detection_time_s": round(detection_time_s, 3) if detection_time_s is not None else None,
		"detection_reason": detection_reason if detection_time_s is not None else "",
		"false_accusation": false_accusation,
		"successful_escape": successful_escape,
		"guard_trigger_time_s": round(trigger_time_s, 3) if trigger_time_s is not None else None,
		"guard_first_response_time_s": round(guard_response_time_s, 3) if guard_response_time_s is not None else None,
		"guard_response_latency_s": guard_latency_s,
		"decide_samples": decide_samples,
		"final_run_outcome": final_run_outcome,
		"final_suspicion": round(final_suspicion, 2),
		"final_intent": str(final_decide.get("intent", "")),
		"final_action": str(final_decide.get("action", "")),
	}


def summarize(results: list[dict[str, Any]]) -> dict[str, Any]:
	total = len(results)
	detected_count = sum(1 for r in results if r["detected"])
	false_accusations = sum(1 for r in results if r["false_accusation"])
	escapes_attempted = sum(1 for r in results if r["attempt_escape"])
	successful_escapes = sum(1 for r in results if r["successful_escape"])
	detection_times = [float(r["detection_time_s"]) for r in results if r["detection_time_s"] is not None]
	guard_latencies = [float(r["guard_response_latency_s"]) for r in results if r["guard_response_latency_s"] is not None]
	triggered = sum(1 for r in results if r["guard_trigger_time_s"] is not None)
	guard_responded = sum(1 for r in results if r["guard_first_response_time_s"] is not None)
	guard_missed = sum(
		1
		for r in results
		if r["guard_trigger_time_s"] is not None and r["guard_first_response_time_s"] is None
	)
	return {
		"scenario_count": total,
		"detected_count": detected_count,
		"detection_rate": round((detected_count / total) if total else 0.0, 3),
		"false_accusations": false_accusations,
		"false_accusation_rate": round((false_accusations / total) if total else 0.0, 3),
		"escapes_attempted": escapes_attempted,
		"successful_escapes": successful_escapes,
		"successful_escape_rate": round((successful_escapes / escapes_attempted) if escapes_attempted else 0.0, 3),
		"avg_detection_time_s": round(statistics.mean(detection_times), 3) if detection_times else None,
		"median_detection_time_s": round(statistics.median(detection_times), 3) if detection_times else None,
		"avg_guard_response_latency_s": round(statistics.mean(guard_latencies), 3) if guard_latencies else None,
		"median_guard_response_latency_s": round(statistics.median(guard_latencies), 3) if guard_latencies else None,
		"guard_triggered_count": triggered,
		"guard_responded_count": guard_responded,
		"guard_missed_response_count": guard_missed,
	}


def write_outputs(output_dir: Path, results: list[dict[str, Any]], summary: dict[str, Any]) -> None:
	output_dir.mkdir(parents=True, exist_ok=True)
	(output_dir / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
	(output_dir / "results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")

	with (output_dir / "results.csv").open("w", encoding="utf-8", newline="") as f:
		if not results:
			return
		writer = csv.DictWriter(f, fieldnames=list(results[0].keys()))
		writer.writeheader()
		for row in results:
			writer.writerow(row)


def print_summary(summary: dict[str, Any], output_dir: Path) -> None:
	print("=== Barnaby Brain Evaluation ===")
	print(f"Scenarios: {summary['scenario_count']}")
	print(f"Detected: {summary['detected_count']} (rate={summary['detection_rate']})")
	print(f"False accusations: {summary['false_accusations']} (rate={summary['false_accusation_rate']})")
	print(
		f"Successful escapes: {summary['successful_escapes']}/{summary['escapes_attempted']} "
		f"(rate={summary['successful_escape_rate']})"
	)
	print(
		f"Guard response latency: avg={summary['avg_guard_response_latency_s']}s "
		f"median={summary['median_guard_response_latency_s']}s"
	)
	print(
		f"Guard responses: {summary['guard_responded_count']}/{summary['guard_triggered_count']} "
		f"(missed={summary['guard_missed_response_count']})"
	)
	print(f"Artifacts: {output_dir}")


def parse_args() -> argparse.Namespace:
	parser = argparse.ArgumentParser(description="Run scripted 20-scenario evaluation harness for Barnaby brain.")
	parser.add_argument("--base-url", default=os.getenv("EVAL_BASE_URL", "http://127.0.0.1:8000"), help="FastAPI base URL.")
	parser.add_argument("--tick-s", type=float, default=0.25, help="Decision tick interval per scenario phase.")
	parser.add_argument(
		"--sleep-s",
		type=float,
		default=0.08,
		help="Sleep per tick. Keep >0 for realistic cooldown/hysteresis timing.",
	)
	parser.add_argument(
		"--output-root",
		default="eval_runs",
		help="Directory where timestamped run outputs are written.",
	)
	parser.add_argument("--limit", type=int, default=0, help="Run only first N scenarios (0 means all).")
	parser.add_argument("--strict", action="store_true", help="Exit non-zero if any false accusation or guard miss occurs.")
	return parser.parse_args()


def main() -> int:
	args = parse_args()
	client = APIClient(args.base_url)
	if not client.healthcheck():
		print(f"Backend not reachable at {args.base_url}. Start FastAPI first.", file=sys.stderr)
		return 2

	scenarios = build_scenarios()
	if args.limit > 0:
		scenarios = scenarios[: args.limit]
	results: list[dict[str, Any]] = []
	for idx, scenario in enumerate(scenarios, start=1):
		print(f"[{idx:02d}/{len(scenarios)}] {scenario.scenario_id}")
		try:
			result = run_scenario(client, scenario, tick_s=args.tick_s, sleep_s=args.sleep_s)
			results.append(result)
		except Exception as exc:
			results.append(
				{
					"scenario_id": scenario.scenario_id,
					"description": scenario.description,
					"hood_on": scenario.hood_on,
					"ground_truth_thief": scenario.ground_truth_thief,
					"attempt_escape": scenario.attempt_escape,
					"detected": None,
					"detection_time_s": None,
					"detection_reason": f"error:{exc}",
					"false_accusation": False,
					"successful_escape": False,
					"guard_trigger_time_s": None,
					"guard_first_response_time_s": None,
					"guard_response_latency_s": None,
					"decide_samples": 0,
					"final_run_outcome": "error",
					"final_suspicion": None,
					"final_intent": "",
					"final_action": "",
				}
			)

	summary = summarize(results)
	run_dir = Path(args.output_root) / _utc_timestamp()
	write_outputs(run_dir, results, summary)
	print_summary(summary, run_dir)

	if args.strict:
		if summary["false_accusations"] > 0 or summary["guard_missed_response_count"] > 0:
			return 1
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
