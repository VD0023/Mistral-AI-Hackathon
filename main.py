import base64
import json
import logging
import os
import re
import time
import zlib
from typing import Any, Optional

import requests
from dotenv import load_dotenv
from fastapi import FastAPI
from pydantic import BaseModel

try:
	import wandb
except Exception:
	wandb = None

load_dotenv()

app = FastAPI()
logger = logging.getLogger("barnaby.brain")
MEMORY_FILE = "barnaby_brain.json"
MEMORY_BINARY_FILE = os.getenv("MEMORY_BINARY_FILE", "barnaby_brain.bin")
BRAIN_STORAGE_MODE = os.getenv("BRAIN_STORAGE_MODE", "binary").strip().lower()
WRITE_JSON_SNAPSHOT = os.getenv("WRITE_JSON_SNAPSHOT", "True").lower() == "true"
BINARY_MAGIC = b"BBIN1"
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://localhost:11434/api/generate")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "tinydolphin")
MISTRAL_API_URL = os.getenv("MISTRAL_API_URL", "https://api.mistral.ai/v1/chat/completions")
MISTRAL_MODEL = os.getenv("MISTRAL_MODEL", "mistral-small-latest")
MISTRAL_API_KEY = os.getenv("MISTRAL_API_KEY", "").strip()
ELEVENLABS_API_KEY = os.getenv("ELEVENLABS_API_KEY", "").strip()
ELEVENLABS_MODEL_ID = os.getenv("ELEVENLABS_MODEL_ID", "eleven_multilingual_v2").strip()
MERCHANT_VOICE_ID = os.getenv("MERCHANT_VOICE_ID", "").strip()
ELEVENLABS_VOICE_ID_CALM = os.getenv("ELEVENLABS_VOICE_ID_CALM", MERCHANT_VOICE_ID).strip()
ELEVENLABS_VOICE_ID_AGITATED = os.getenv("ELEVENLABS_VOICE_ID_AGITATED", MERCHANT_VOICE_ID).strip()
ENABLE_ELEVENLABS_MUTTER = os.getenv("ENABLE_ELEVENLABS_MUTTER", "True").lower() == "true"
LLM_PROVIDER = os.getenv("LLM_PROVIDER", "auto").strip().lower()
USE_LLM_REPHRASE = os.getenv("USE_LLM_REPHRASE", os.getenv("USE_LOCAL_MOCK", "True")).lower() == "true"
ENABLE_WANDB = os.getenv("ENABLE_WANDB", "False").lower() == "true"
USE_LLM_SKILL_ROUTER = os.getenv("USE_LLM_SKILL_ROUTER", "True").lower() == "true"
HUGGINGFACE_API_KEY = os.getenv("HUGGINGFACE_API_KEY", "").strip()
HF_CLASSIFIER_URL = os.getenv(
	"HF_CLASSIFIER_URL",
	"https://api-inference.huggingface.co/models/facebook/bart-large-mnli",
).strip()
MEMORY_WARN_DEDUP_WINDOW_SECONDS = max(0.0, float(os.getenv("MEMORY_WARN_DEDUP_WINDOW_SECONDS", "10.0")))

_memory_warn_last_ts: dict[str, float] = {}

BLACKBOARD_DEFAULTS: dict[str, Any] = {
	"threat_level": 10.0,
	"suspect_confidence": 0.1,
	"last_seen_pos": None,
	"key_missing": False,
	"player_visible": False,
	"guard_task": "idle",
	"last_hf_classification": "Waiting for item...",
}
BLACKBOARD_TTLS: dict[str, float] = {
	"threat_level": 2.5,
	"suspect_confidence": 2.5,
	"last_seen_pos": 4.0,
	"key_missing": 12.0,
	"player_visible": 1.1,
	"guard_task": 2.0,
	"last_hf_classification": 18.0,
}
CONFIDENCE_MONITOR_MAX = 0.45
CONFIDENCE_ACCUSE_MIN = 0.75
CONFIDENCE_HYSTERESIS_MARGIN = 0.05
INTENT_MIN_HOLD_SECONDS = 1.2
CONFIDENCE_SMOOTH_ALPHA = 0.45

wandb_run = None
if ENABLE_WANDB and wandb is not None:
	try:
		wandb_run = wandb.init(
			entity="vanshdahiya00-macquarie-university",
			project="smart-npc-hackathon",
			settings=wandb.Settings(start_method="thread"),
		)
	except Exception:
		wandb_run = None


class ChatRequest(BaseModel):
	message: str
	choice_id: Optional[str] = None


class WorldEventRequest(BaseModel):
	event_type: str
	intensity: float = 1.0
	metadata: Optional[dict[str, Any]] = None


class DecideObservation(BaseModel):
	hood_on: bool = False
	distance: float = 999.0
	los: bool = False
	player_speed: float = 0.0
	near_key: bool = False
	key_missing: bool = False
	last_seen_pos: Optional[dict[str, float]] = None
	recent_actions: list[str] = []
	interaction_active: bool = False
	metadata: Optional[dict[str, Any]] = None


class DecideRequest(BaseModel):
	npc_id: str = "barnaby"
	guard_id: str = "guard"
	observation: DecideObservation


class AmbientMutterRequest(BaseModel):
	npc_id: str = "barnaby"
	intent: str = "monitor"
	suspicion: float = 0.0
	temper: float = 0.0
	current_skill: str = "monitor"
	location_hint: str = "counter"


def clamp(value: int, low: int, high: int) -> int:
	return max(low, min(high, int(value)))


def clampf(value: float, low: float, high: float) -> float:
	return max(low, min(high, float(value)))


def default_memory() -> dict:
	return {
		"interactions": 0,
		"trust": 45,
		"suspicion": 12,
		"temper": 18,
		"notoriety": 0,
		"has_stolen": False,
		"thief_recognized": False,
		"last_hood_on": False,
		"caught": False,
		"last_intent": "none",
		"run_phase": "need_distraction",
		"run_outcome": "active",
		"run_reason": "",
		"decision_dynamics": {
			"smoothed_confidence": 0.12,
			"stable_intent": "monitor",
			"last_switch_ts": 0.0,
		},
		"episode_last_signature": "",
		"episode_last_ts": 0,
		"skill_cooldowns": {},
		"blackboard": {
			"threat_level": 10,
			"last_seen_pos": None,
			"suspect_confidence": 0.1,
			"key_missing": False,
			"player_visible": False,
			"guard_task": "idle",
			"last_hf_classification": "Waiting for item...",
			"ttl": {},
		},
		"episodes": [],
		}


def _fallback_item_classification(item_name: str) -> dict[str, Any]:
	name = item_name.lower()
	weapon_tokens = ["dagger", "knife", "sword", "blade", "axe", "mace", "spear", "weapon"]
	valuable_tokens = ["coin", "gold", "chest", "gem", "jewel", "ring", "treasure", "silver"]
	if any(token in name for token in weapon_tokens):
		return {"label": "threat", "confidence": 0.92, "source": "fallback"}
	if any(token in name for token in valuable_tokens):
		return {"label": "valuable", "confidence": 0.9, "source": "fallback"}
	return {"label": "trash", "confidence": 0.72, "source": "fallback"}


def classify_thrown_item(item_name: str) -> dict[str, Any]:
	"""Uses Hugging Face zero-shot classification for semantic item understanding."""
	item = (item_name or "mystery object").strip()
	if not HUGGINGFACE_API_KEY:
		return _fallback_item_classification(item)

	headers = {"Authorization": f"Bearer {HUGGINGFACE_API_KEY}"}
	payload = {
		"inputs": f"A person just threw a {item} onto the floor.",
		"parameters": {
			"candidate_labels": ["valuable treasure", "harmless trash", "dangerous weapon"],
		},
	}

	try:
		response = requests.post(HF_CLASSIFIER_URL, headers=headers, json=payload, timeout=4)
		if response.status_code != 200:
			fallback = _fallback_item_classification(item)
			fallback["source"] = f"hf_http_{response.status_code}"
			return fallback

		result = response.json()
		if not isinstance(result, dict):
			fallback = _fallback_item_classification(item)
			fallback["source"] = "hf_invalid_response"
			return fallback

		labels = result.get("labels", [])
		scores = result.get("scores", [])
		if not isinstance(labels, list) or not labels or not isinstance(scores, list) or not scores:
			fallback = _fallback_item_classification(item)
			fallback["source"] = "hf_missing_scores"
			return fallback

		top_label = str(labels[0]).lower()
		score = clampf(float(scores[0]), 0.0, 1.0)

		if "weapon" in top_label:
			return {"label": "threat", "confidence": score, "source": "hf"}
		if "treasure" in top_label or "valuable" in top_label:
			return {"label": "valuable", "confidence": score, "source": "hf"}
		return {"label": "trash", "confidence": score, "source": "hf"}
	except Exception:
		fallback = _fallback_item_classification(item)
		fallback["source"] = "hf_exception"
		return fallback


def _read_json_memory(path: str) -> Optional[dict]:
	if not os.path.exists(path):
		return None
	try:
		with open(path, "r", encoding="utf-8") as f:
			raw = json.load(f)
		if isinstance(raw, dict):
			return raw
		_memory_warn(
			key=f"json_invalid_type:{path}",
			message="JSON memory file %s did not contain an object (got %s); ignoring persisted state.",
			args=(path, type(raw).__name__),
		)
	except Exception as ex:
		_memory_warn(
			key=f"json_exception:{path}:{type(ex).__name__}",
			message="Failed to read JSON memory file %s (%s: %s); ignoring persisted state.",
			args=(path, type(ex).__name__, str(ex)),
		)
		return None
	return None


def _write_json_memory(path: str, mem: dict) -> None:
	with open(path, "w", encoding="utf-8") as f:
		json.dump(mem, f, indent=2)


def _read_binary_memory(path: str) -> Optional[dict]:
	if not os.path.exists(path):
		return None
	try:
		with open(path, "rb") as f:
			data = f.read()
		if not data.startswith(BINARY_MAGIC):
			_memory_warn(
				key=f"binary_magic_mismatch:{path}",
				message="Binary memory file %s has invalid magic header; ignoring persisted state.",
				args=(path,),
			)
			return None
		compressed = data[len(BINARY_MAGIC) :]
		payload = zlib.decompress(compressed).decode("utf-8")
		raw = json.loads(payload)
		if isinstance(raw, dict):
			return raw
		_memory_warn(
			key=f"binary_invalid_type:{path}",
			message="Binary memory file %s did not decode to an object (got %s); ignoring persisted state.",
			args=(path, type(raw).__name__),
		)
	except Exception as ex:
		_memory_warn(
			key=f"binary_exception:{path}:{type(ex).__name__}",
			message="Failed to read binary memory file %s (%s: %s); ignoring persisted state.",
			args=(path, type(ex).__name__, str(ex)),
		)
		return None
	return None


def _memory_warn(key: str, message: str, args: tuple[Any, ...] = ()) -> None:
	now = time.time()
	last = float(_memory_warn_last_ts.get(key, 0.0))
	if now - last < MEMORY_WARN_DEDUP_WINDOW_SECONDS:
		return
	_memory_warn_last_ts[key] = now
	logger.warning(message, *args)


def _write_binary_memory(path: str, mem: dict) -> None:
	payload = json.dumps(mem, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
	compressed = zlib.compress(payload, level=6)
	with open(path, "wb") as f:
		f.write(BINARY_MAGIC + compressed)


def load_memory() -> dict:
	mem = default_memory()
	mode = BRAIN_STORAGE_MODE if BRAIN_STORAGE_MODE in {"binary", "json", "auto"} else "binary"
	raw: Optional[dict] = None

	if mode == "json":
		raw = _read_json_memory(MEMORY_FILE)
	elif mode == "binary":
		raw = _read_binary_memory(MEMORY_BINARY_FILE)
		if raw is None:
			raw = _read_json_memory(MEMORY_FILE)
	else:
		raw = _read_binary_memory(MEMORY_BINARY_FILE)
		if raw is None:
			raw = _read_json_memory(MEMORY_FILE)

	if isinstance(raw, dict):
		mem.update(raw)
	return mem


def save_memory(mem: dict) -> None:
	mode = BRAIN_STORAGE_MODE if BRAIN_STORAGE_MODE in {"binary", "json", "auto"} else "binary"
	if mode == "json":
		_write_json_memory(MEMORY_FILE, mem)
		return

	_write_binary_memory(MEMORY_BINARY_FILE, mem)
	if WRITE_JSON_SNAPSHOT or mode == "auto":
		_write_json_memory(MEMORY_FILE, mem)


def reset_memory_to_default() -> dict:
	mem = default_memory()
	# Always reset binary + JSON together so runtime and debug snapshots stay aligned.
	_write_binary_memory(MEMORY_BINARY_FILE, mem)
	_write_json_memory(MEMORY_FILE, mem)
	return mem


def classify_intent(message: str, choice_id: Optional[str]) -> str:
	text = (message or "").strip().lower()
	if choice_id:
		return choice_id.strip().lower()

	if any(token in text for token in ["look around", "having a look", "browse", "just looking"]):
		return "look_around"
	if any(token in text for token in ["steal", "snatch", "grab", "take it"]):
		return "steal"
	if any(token in text for token in ["discount", "cheaper", "price", "deal"]):
		return "bargain"
	if any(token in text for token in ["sorry", "apologize", "forgive", "mercy"]):
		return "apologize"
	if any(token in text for token in ["threat", "or else", "hurt", "break"]):
		return "threaten"
	if any(token in text for token in ["hello", "greet", "hail", "good day", "praise"]):
		return "charm"
	if any(token in text for token in ["rush", "now", "hurry", "pressure"]):
		return "pressure"
	if any(token in text for token in ["run", "escape", "flee"]):
		return "run"
	return "talk"


def derive_emotion(mem: dict, turn_caught: bool = False) -> str:
	if turn_caught:
		return "hostile"
	if mem.get("temper", 0) >= 80:
		return "hostile"
	if mem.get("temper", 0) >= 45 or mem.get("suspicion", 0) >= 65:
		return "annoyed"
	if mem.get("trust", 0) >= 70 and mem.get("suspicion", 0) < 40:
		return "pleased"
	return "neutral"


def build_state(mem: dict, turn_caught: bool = False) -> dict:
	return {
		"emotion": derive_emotion(mem, turn_caught),
		"is_caught": turn_caught,
		"trust": int(mem.get("trust", 0)),
		"suspicion": int(mem.get("suspicion", 0)),
		"temper": int(mem.get("temper", 0)),
		"interactions": int(mem.get("interactions", 0)),
		"has_stolen": bool(mem.get("has_stolen", False)),
		"thief_recognized": bool(mem.get("thief_recognized", False)),
		"last_hood_on": bool(mem.get("last_hood_on", False)),
		"run_phase": str(mem.get("run_phase", "need_distraction")),
		"run_outcome": str(mem.get("run_outcome", "active")),
		"run_reason": str(mem.get("run_reason", "")),
	}


def _blackboard(mem: dict) -> dict:
	bb = mem.get("blackboard")
	if not isinstance(bb, dict):
		bb = {}
	mem["blackboard"] = bb

	ttl = bb.get("ttl")
	if not isinstance(ttl, dict):
		ttl = {}
	bb["ttl"] = ttl

	for key, default_val in BLACKBOARD_DEFAULTS.items():
		if key == "key_missing":
			bb.setdefault(key, bool(mem.get("has_stolen", False)))
		else:
			bb.setdefault(key, default_val)

	_bb_prune_expired(bb)
	return bb


def _bb_set(bb: dict, key: str, value: Any, ttl_seconds: Optional[float] = None) -> None:
	bb[key] = value
	ttl = bb.get("ttl")
	if not isinstance(ttl, dict):
		ttl = {}
		bb["ttl"] = ttl
	duration = BLACKBOARD_TTLS.get(key) if ttl_seconds is None else float(ttl_seconds)
	if duration is not None and duration > 0.0:
		ttl[key] = time.time() + float(duration)


def _bb_get(bb: dict, key: str) -> Any:
	default_val = BLACKBOARD_DEFAULTS.get(key)
	ttl = bb.get("ttl")
	if not isinstance(ttl, dict):
		return bb.get(key, default_val)
	expires_at = ttl.get(key)
	if isinstance(expires_at, (int, float)) and time.time() > float(expires_at):
		return default_val
	return bb.get(key, default_val)


def _bb_prune_expired(bb: dict) -> None:
	ttl = bb.get("ttl")
	if not isinstance(ttl, dict):
		return
	now = time.time()
	for key, expires_at in list(ttl.items()):
		if not isinstance(expires_at, (int, float)):
			del ttl[key]
			continue
		if now <= float(expires_at):
			continue
		if key in BLACKBOARD_DEFAULTS:
			bb[key] = BLACKBOARD_DEFAULTS[key]
		del ttl[key]


def _bb_ttl_remaining(bb: dict, key: str) -> float:
	ttl = bb.get("ttl")
	if not isinstance(ttl, dict):
		return 0.0
	expires_at = ttl.get(key)
	if not isinstance(expires_at, (int, float)):
		return 0.0
	return max(0.0, float(expires_at) - time.time())


def _bb_client_snapshot(bb: dict) -> dict[str, Any]:
	# Export shared keys plus TTL debug for guard/Barnaby coordination visibility.
	snapshot: dict[str, Any] = {}
	ttl_remaining: dict[str, float] = {}
	for key in BLACKBOARD_DEFAULTS.keys():
		snapshot[key] = _bb_get(bb, key)
		ttl_remaining[key] = round(_bb_ttl_remaining(bb, key), 3)
	snapshot["ttl_remaining"] = ttl_remaining
	return snapshot


def _episodes(mem: dict) -> list[dict]:
	episodes = mem.get("episodes")
	if not isinstance(episodes, list):
		episodes = []
	mem["episodes"] = episodes
	return episodes


def _distance_bucket(distance: float) -> str:
	if distance < 2.2:
		return "near"
	if distance < 5.2:
		return "mid"
	return "far"


def _where_from_observation(observation: dict[str, Any]) -> str:
	if bool(observation.get("near_key", False)) or bool(observation.get("key_missing", False)):
		return "counter_zone"
	distance = float(observation.get("distance", 999.0))
	if distance < 2.2:
		return "front_counter"
	if distance < 5.2:
		return "shop_floor"
	return "entry_zone"


def _compact_episode_from_legacy(entry: dict[str, Any]) -> dict[str, Any]:
	# Backward compatibility for old "summary"-style episodes.
	what = str(entry.get("what", "legacy_event"))
	if what == "legacy_event":
		summary = str(entry.get("summary", "")).lower()
		if "high-confidence" in summary or "suspect" in summary:
			what = "accuse"
		elif "investigating" in summary:
			what = "investigate_last_seen"
	result = str(entry.get("result", "uncertain"))
	if result not in {"escalated", "deescalated", "uncertain"}:
		result = "uncertain"
	ep = {
		"ts": int(entry.get("ts", entry.get("timestamp", int(time.time())))),
		"who": str(entry.get("who", "player")),
		"what": what,
		"where": str(entry.get("where", "shop_floor")),
		"result": result,
		"confidence": round(clampf(float(entry.get("confidence", 0.5)), 0.0, 1.0), 3),
		"hood_on": bool(entry.get("hood_on", False)),
		"key_missing": bool(entry.get("key_missing", False)),
		"player_visible": bool(entry.get("player_visible", entry.get("los", False))),
		"near_key": bool(entry.get("near_key", False)),
		"distance_bucket": str(entry.get("distance_bucket", _distance_bucket(float(entry.get("distance", 999.0))))),
		"intent": str(entry.get("intent", "monitor")),
	}
	return ep


def _record_episode(
	mem: dict,
	who: str,
	what: str,
	where: str,
	result: str,
	confidence: float,
	observation: dict[str, Any],
	intent: str,
) -> None:
	episodes = _episodes(mem)
	entry = {
		"ts": int(time.time()),
		"who": who,
		"what": what,
		"where": where,
		"result": result,
		"confidence": round(clampf(confidence, 0.0, 1.0), 3),
		"hood_on": bool(observation.get("hood_on", False)),
		"key_missing": bool(observation.get("key_missing", False)),
		"player_visible": bool(observation.get("los", False)),
		"near_key": bool(observation.get("near_key", False)),
		"distance_bucket": _distance_bucket(float(observation.get("distance", 999.0))),
		"intent": intent,
	}

	# Compact dedupe for repeated ticks with same event signature.
	signature = "|".join(
		[
			entry["who"],
			entry["what"],
			entry["where"],
			entry["result"],
			str(entry["hood_on"]),
			str(entry["key_missing"]),
			str(entry["player_visible"]),
		]
	)
	last_signature = str(mem.get("episode_last_signature", ""))
	last_ts = int(mem.get("episode_last_ts", 0))
	now = int(time.time())
	if episodes and signature == last_signature and now - last_ts <= 3:
		episodes[-1]["confidence"] = round(
			clampf((float(episodes[-1].get("confidence", 0.5)) + entry["confidence"]) * 0.5, 0.0, 1.0),
			3,
		)
		episodes[-1]["ts"] = now
	else:
		episodes.append(entry)
		mem["episode_last_signature"] = signature
		mem["episode_last_ts"] = now

	if len(episodes) > 32:
		del episodes[: len(episodes) - 32]


def _episode_similarity(episode: dict[str, Any], cue: dict[str, Any]) -> float:
	score = 0.0
	if bool(episode.get("hood_on", False)) == bool(cue.get("hood_on", False)):
		score += 0.24
	if bool(episode.get("key_missing", False)) == bool(cue.get("key_missing", False)):
		score += 0.18
	if bool(episode.get("player_visible", False)) == bool(cue.get("los", False)):
		score += 0.15
	if bool(episode.get("near_key", False)) == bool(cue.get("near_key", False)):
		score += 0.14
	if str(episode.get("distance_bucket", "")) == _distance_bucket(float(cue.get("distance", 999.0))):
		score += 0.12
	ep_what = str(episode.get("what", ""))
	recent_actions = [str(a).lower() for a in cue.get("recent_actions", [])]
	if ep_what != "" and any(ep_what in act or act in ep_what for act in recent_actions):
		score += 0.12
	if str(episode.get("intent", "")) == str(cue.get("intent_hint", "")):
		score += 0.05
	return clampf(score, 0.0, 1.0)


def _retrieve_similar_episodes(mem: dict, cue: dict[str, Any], top_k: int = 3) -> list[dict[str, Any]]:
	episodes = _episodes(mem)
	scored: list[dict[str, Any]] = []
	for raw in episodes:
		if not isinstance(raw, dict):
			continue
		episode = _compact_episode_from_legacy(raw)
		sim = _episode_similarity(episode, cue)
		if sim < 0.35:
			continue
		weight = round(sim * clampf(float(episode.get("confidence", 0.5)), 0.0, 1.0), 4)
		candidate = episode.copy()
		candidate["similarity"] = round(sim, 4)
		candidate["weight"] = weight
		scored.append(candidate)
	scored.sort(key=lambda e: float(e.get("weight", 0.0)), reverse=True)
	return scored[: max(1, top_k)]


def _apply_episode_influence(
	mem: dict,
	perception: dict[str, Any],
	belief: dict[str, Any],
	base_intent: str,
	base_confidence: float,
) -> dict[str, Any]:
	if not bool(perception.get("interaction_active", False)):
		return {
			"confidence": base_confidence,
			"intent": base_intent,
			"episodes": [],
			"memory_bias": 0.0,
		}

	cue = perception.copy()
	cue["intent_hint"] = base_intent
	similar = _retrieve_similar_episodes(mem, cue, top_k=3)
	if not similar:
		return {
			"confidence": base_confidence,
			"intent": base_intent,
			"episodes": [],
			"memory_bias": 0.0,
		}

	result_sign = {"escalated": 1.0, "deescalated": -1.0, "uncertain": 0.0}
	total_weight = 0.0
	weighted_sum = 0.0
	for ep in similar:
		weight = float(ep.get("weight", 0.0))
		sign = result_sign.get(str(ep.get("result", "uncertain")), 0.0)
		total_weight += weight
		weighted_sum += weight * sign
	bias = (weighted_sum / total_weight) if total_weight > 0.0001 else 0.0

	delta_suspicion = int(round(clampf(bias * 6.0, -5.0, 5.0)))
	mem["suspicion"] = clamp(mem.get("suspicion", 0) + delta_suspicion, 0, 100)
	adjusted_confidence = clampf(base_confidence + bias * 0.12, 0.0, 1.0)

	intent = base_intent
	if base_intent == "monitor" and bias > 0.35:
		intent = "investigate"
	elif base_intent == "investigate" and bias > 0.55:
		intent = "accuse"
	elif base_intent == "investigate" and bias < -0.45:
		intent = "monitor"

	return {
		"confidence": adjusted_confidence,
		"intent": intent,
		"episodes": [
			{
				"what": ep.get("what", ""),
				"where": ep.get("where", ""),
				"result": ep.get("result", ""),
				"confidence": ep.get("confidence", 0.0),
				"similarity": ep.get("similarity", 0.0),
			}
			for ep in similar
		],
		"memory_bias": round(bias, 4),
	}


def _skill_ready(mem: dict, skill_name: str, cooldown_seconds: float) -> bool:
	cooldowns = mem.get("skill_cooldowns")
	if not isinstance(cooldowns, dict):
		cooldowns = {}
	mem["skill_cooldowns"] = cooldowns
	now = time.time()
	last = float(cooldowns.get(skill_name, 0.0))
	if now - last >= cooldown_seconds:
		cooldowns[skill_name] = now
		return True
	return False


def _skill_cooldowns_remaining(mem: dict) -> dict[str, float]:
	cooldowns = mem.get("skill_cooldowns")
	if not isinstance(cooldowns, dict):
		return {skill: 0.0 for skill in SKILL_IDS}
	now = time.time()
	remaining: dict[str, float] = {}
	for skill in SKILL_IDS:
		cooldown = float(SKILL_COOLDOWNS.get(skill, 0.0))
		last = float(cooldowns.get(skill, 0.0))
		left = max(0.0, cooldown - (now - last))
		remaining[skill] = round(left, 3)
	return remaining


def _compute_suspect_confidence(mem: dict, obs: dict[str, Any]) -> float:
	conf = 0.12
	if bool(mem.get("thief_recognized", False)):
		conf += 0.33
	if bool(obs.get("key_missing", False)):
		conf += 0.08
	if bool(obs.get("los", False)):
		conf += 0.18
	if bool(obs.get("near_key", False)):
		conf += 0.16

	distance = float(obs.get("distance", 999.0))
	if distance < 2.1:
		conf += 0.1
	elif distance > 6.0:
		conf -= 0.06

	speed = float(obs.get("player_speed", 0.0))
	if speed > 3.2:
		conf += 0.08

	recent_actions = [str(a).lower() for a in obs.get("recent_actions", [])]
	if any(a in recent_actions for a in ["steal_key", "rush_key", "sprint", "sprint_to_key"]):
		conf += 0.12

	if bool(obs.get("hood_on", False)):
		conf -= 0.2

	return clampf(conf, 0.0, 1.0)


SKILL_IDS = ("wake_guard", "patrol_counter", "question_player", "block_exit", "chase_player")
SKILL_COOLDOWNS = {
	"wake_guard": 1.6,
	"patrol_counter": 3.0,
	"question_player": 2.8,
	"block_exit": 1.3,
	"chase_player": 1.0,
}
SKILL_TARGETS = {
	"wake_guard": "guard",
	"patrol_counter": "counter",
	"question_player": "player",
	"block_exit": "exit_door",
	"chase_player": "player",
}


def _decide_intent(confidence: float, suspicion: int) -> str:
	_ = suspicion
	if confidence > CONFIDENCE_ACCUSE_MIN:
		return "accuse"
	if confidence >= CONFIDENCE_MONITOR_MAX:
		return "investigate"
	return "monitor"


def _decision_dynamics(mem: dict) -> dict[str, Any]:
	dyn = mem.get("decision_dynamics")
	if not isinstance(dyn, dict):
		dyn = {}
	mem["decision_dynamics"] = dyn
	dyn.setdefault("smoothed_confidence", 0.12)
	dyn.setdefault("stable_intent", "monitor")
	dyn.setdefault("last_switch_ts", 0.0)
	return dyn


def _intent_from_confidence(confidence: float) -> str:
	if confidence > CONFIDENCE_ACCUSE_MIN:
		return "accuse"
	if confidence >= CONFIDENCE_MONITOR_MAX:
		return "investigate"
	return "monitor"


def _hysteresis_intent_transition(current_intent: str, confidence: float) -> str:
	if current_intent == "monitor":
		if confidence > CONFIDENCE_ACCUSE_MIN + CONFIDENCE_HYSTERESIS_MARGIN:
			return "accuse"
		if confidence >= CONFIDENCE_MONITOR_MAX + CONFIDENCE_HYSTERESIS_MARGIN:
			return "investigate"
		return "monitor"
	if current_intent == "investigate":
		if confidence > CONFIDENCE_ACCUSE_MIN + CONFIDENCE_HYSTERESIS_MARGIN:
			return "accuse"
		if confidence < CONFIDENCE_MONITOR_MAX - CONFIDENCE_HYSTERESIS_MARGIN:
			return "monitor"
		return "investigate"
	if current_intent == "accuse":
		if confidence < CONFIDENCE_MONITOR_MAX - CONFIDENCE_HYSTERESIS_MARGIN:
			return "monitor"
		if confidence < CONFIDENCE_ACCUSE_MIN - CONFIDENCE_HYSTERESIS_MARGIN:
			return "investigate"
		return "accuse"
	return _intent_from_confidence(confidence)


def _extract_skill_name(raw_reply: str) -> str:
	text = re.sub(r"[^a-z_]+", "_", str(raw_reply).strip().lower())
	text = re.sub(r"_+", "_", text).strip("_")
	if text in SKILL_IDS:
		return text
	for skill in SKILL_IDS:
		if skill in text:
			return skill
	return ""


def _mistral_pick_skill(prompt: str) -> str:
	if not MISTRAL_API_KEY:
		return ""
	try:
		r = requests.post(
			MISTRAL_API_URL,
			json={
				"model": MISTRAL_MODEL,
				"messages": [
					{"role": "system", "content": "You are a deterministic skill router for a stealth NPC."},
					{"role": "user", "content": prompt},
				],
				"temperature": 0.0,
				"max_tokens": 12,
			},
			headers={
				"Authorization": f"Bearer {MISTRAL_API_KEY}",
				"Content-Type": "application/json",
			},
			timeout=8,
		)
		payload = r.json()
		choices = payload.get("choices", [])
		if not isinstance(choices, list) or not choices:
			return ""
		message = choices[0].get("message", {})
		content = message.get("content", "")
		if isinstance(content, list):
			content = " ".join(str(part.get("text", "")).strip() for part in content if isinstance(part, dict))
		return str(content).strip()
	except Exception:
		return ""


def _ollama_pick_skill(prompt: str) -> str:
	try:
		r = requests.post(
			OLLAMA_URL,
			json={
				"model": OLLAMA_MODEL,
				"prompt": prompt,
				"stream": False,
				"options": {"temperature": 0.0, "num_predict": 12, "stop": ["\n"]},
			},
			timeout=8,
		)
		return str(r.json().get("response", "")).strip()
	except Exception:
		return ""


def _llm_choose_skill(intent: str, perception: dict[str, Any], belief: dict[str, Any]) -> str:
	if not USE_LLM_SKILL_ROUTER:
		return ""
	provider = _resolve_llm_provider()
	recent = ", ".join(list(perception.get("recent_actions", []))[:6])
	prompt = (
		"Pick exactly one skill id from: wake_guard, patrol_counter, question_player, block_exit, chase_player.\n"
		"If none fit, output: none.\n"
		f"intent={intent}, confidence={belief['confidence']:.2f}, threat={belief['threat_level']:.1f}, "
		f"los={perception['los']}, distance={perception['distance']:.2f}, key_missing={perception['key_missing']}, "
		f"near_key={perception['near_key']}, player_speed={perception['player_speed']:.2f}, recent_actions={recent}\n"
		"Output only the skill id or none."
	)
	reply = _mistral_pick_skill(prompt) if provider == "mistral" else _ollama_pick_skill(prompt)
	return _extract_skill_name(reply)


def _default_skill_order(intent: str, perception: dict[str, Any], belief: dict[str, Any]) -> list[str]:
	if intent == "accuse":
		return ["chase_player", "wake_guard", "block_exit", "question_player", "patrol_counter"]
	if intent == "investigate":
		if perception["key_missing"]:
			return ["block_exit", "wake_guard", "question_player", "chase_player", "patrol_counter"]
		if perception["near_key"]:
			return ["question_player", "patrol_counter", "wake_guard", "block_exit", "chase_player"]
		return ["question_player", "patrol_counter", "block_exit", "wake_guard", "chase_player"]
	return ["patrol_counter", "question_player", "wake_guard", "block_exit", "chase_player"]


def _skill_precondition(skill: str, intent: str, perception: dict[str, Any], belief: dict[str, Any]) -> tuple[bool, str]:
	confidence = float(belief["confidence"])
	threat = float(belief["threat_level"])
	distance = float(perception["distance"])
	los = bool(perception["los"])
	key_missing = bool(perception["key_missing"])
	near_key = bool(perception["near_key"])
	interaction_active = bool(perception["interaction_active"])
	player_speed = float(perception["player_speed"])

	if skill == "wake_guard":
		if confidence >= 0.45 or threat >= 50.0 or key_missing:
			return True, "Wake guard due to elevated threat."
		return False, "Needs medium confidence/threat or missing key."
	if skill == "patrol_counter":
		if interaction_active:
			return False, "Skip patrol while in direct interaction."
		if near_key or key_missing or intent == "investigate":
			return True, "Patrol counter zone for evidence."
		return False, "Needs key-adjacent suspicion or investigate intent."
	if skill == "question_player":
		if interaction_active:
			return False, "Already interacting with player."
		if los and distance <= 4.8:
			return True, "Question player in close visual range."
		return False, "Needs line-of-sight and closer distance."
	if skill == "block_exit":
		if key_missing or confidence >= 0.6 or threat >= 60.0:
			return True, "Block the door to prevent escape."
		return False, "Needs missing key or strong suspect confidence."
	if skill == "chase_player":
		if los and (confidence >= 0.75 or threat >= 70.0 or (key_missing and player_speed > 1.5)):
			return True, "Immediate pursuit conditions met."
		return False, "Needs high confidence/threat and visual contact."
	return False, "Unknown skill."


def _stage_perception(obs: dict[str, Any]) -> dict[str, Any]:
	# Normalize and freeze incoming observation for deterministic downstream stages.
	perception = {
		"hood_on": bool(obs.get("hood_on", False)),
		"distance": float(obs.get("distance", 999.0)),
		"los": bool(obs.get("los", False)),
		"player_speed": float(obs.get("player_speed", 0.0)),
		"near_key": bool(obs.get("near_key", False)),
		"key_missing": bool(obs.get("key_missing", False)),
		"last_seen_pos": obs.get("last_seen_pos"),
		"recent_actions": [str(a).lower() for a in obs.get("recent_actions", [])][:8],
		"interaction_active": bool(obs.get("interaction_active", False)),
		"metadata": obs.get("metadata", {}),
	}
	return perception


def _stage_belief_update(mem: dict, perception: dict[str, Any]) -> dict[str, Any]:
	# Update internal belief state from current perception.
	if perception["los"]:
		mem["suspicion"] = clamp(mem.get("suspicion", 0) + 2, 0, 100)
		mem["temper"] = clamp(mem.get("temper", 0) + 1, 0, 100)
	else:
		mem["suspicion"] = clamp(mem.get("suspicion", 0) - 1, 0, 100)

	if perception["near_key"] and not perception["key_missing"]:
		mem["suspicion"] = clamp(mem.get("suspicion", 0) + 2, 0, 100)

	if perception["key_missing"]:
		mem["has_stolen"] = True

	confidence = _compute_suspect_confidence(mem, perception)
	bb = _blackboard(mem)
	_bb_set(bb, "suspect_confidence", round(confidence, 3))
	_bb_set(bb, "key_missing", perception["key_missing"])
	_bb_set(bb, "player_visible", bool(perception["los"]))
	if perception["last_seen_pos"] is not None:
		_bb_set(bb, "last_seen_pos", perception["last_seen_pos"])

	threat = clampf(mem.get("suspicion", 0) * 0.65 + confidence * 35.0, 0.0, 100.0)
	_bb_set(bb, "threat_level", round(threat, 1))
	_bb_prune_expired(bb)

	return {
		"confidence": confidence,
		"threat_level": threat,
		"suspicion": int(mem.get("suspicion", 0)),
		"temper": int(mem.get("temper", 0)),
		"blackboard": bb,
	}


def _stage_intent_selection(mem: dict, perception: dict[str, Any], belief: dict[str, Any]) -> dict[str, Any]:
	base_confidence = float(belief["confidence"])
	suspicion = int(mem.get("suspicion", 0))
	base_intent = _decide_intent(base_confidence, suspicion)
	influence = _apply_episode_influence(mem, perception, belief, base_intent, base_confidence)
	memory_adjusted_confidence = float(influence["confidence"])
	memory_adjusted_intent = str(influence["intent"])

	dyn = _decision_dynamics(mem)
	prev_smoothed_conf = clampf(float(dyn.get("smoothed_confidence", memory_adjusted_confidence)), 0.0, 1.0)
	smoothed_conf = clampf(
		prev_smoothed_conf + (memory_adjusted_confidence - prev_smoothed_conf) * CONFIDENCE_SMOOTH_ALPHA,
		0.0,
		1.0,
	)
	stable_before = str(dyn.get("stable_intent", "monitor"))
	proposed = _hysteresis_intent_transition(stable_before, smoothed_conf)
	now = time.time()
	last_switch_ts = float(dyn.get("last_switch_ts", 0.0))
	time_since_switch = max(0.0, now - last_switch_ts)
	locked = proposed != stable_before and time_since_switch < INTENT_MIN_HOLD_SECONDS

	intent = stable_before if locked else proposed
	if intent != stable_before:
		dyn["last_switch_ts"] = now
	dyn["stable_intent"] = intent
	dyn["smoothed_confidence"] = round(smoothed_conf, 4)
	band = "high" if smoothed_conf > CONFIDENCE_ACCUSE_MIN else ("medium" if smoothed_conf >= CONFIDENCE_MONITOR_MAX else "low")

	return {
		"intent": intent,
		"base_intent": base_intent,
		"memory_adjusted_intent": memory_adjusted_intent,
		"base_confidence": round(base_confidence, 3),
		"memory_adjusted_confidence": round(memory_adjusted_confidence, 3),
		"effective_confidence": round(smoothed_conf, 3),
		"smoothed_confidence": round(smoothed_conf, 3),
		"hysteresis_locked": locked,
		"time_since_switch": round(time_since_switch, 3),
		"intent_before": stable_before,
		"intent_proposed": proposed,
		"confidence_band": band,
		"memory_bias": float(influence["memory_bias"]),
		"similar_episodes": list(influence["episodes"]),
	}


def _stage_skill_action(
	mem: dict,
	perception: dict[str, Any],
	belief: dict[str, Any],
	intent_stage: dict[str, Any],
) -> dict[str, Any]:
	intent = str(intent_stage["intent"])
	bb = belief["blackboard"]
	confidence = float(belief["confidence"])
	threat = float(belief["threat_level"])

	llm_skill = _llm_choose_skill(intent, perception, belief)
	candidates: list[str] = []
	if llm_skill in SKILL_IDS:
		candidates.append(llm_skill)
	for fallback_skill in _default_skill_order(intent, perception, belief):
		if fallback_skill not in candidates:
			candidates.append(fallback_skill)

	rejected: list[str] = []
	action = "monitor"
	target = "player"
	reason = "No skill met preconditions; monitoring."
	source = "deterministic"

	for skill in candidates:
		ok, precondition_reason = _skill_precondition(skill, intent, perception, belief)
		if not ok:
			rejected.append(f"{skill}: precondition ({precondition_reason})")
			continue
		cooldown = float(SKILL_COOLDOWNS.get(skill, 1.5))
		if not _skill_ready(mem, skill, cooldown):
			rejected.append(f"{skill}: cooldown")
			continue
		action = skill
		target = str(SKILL_TARGETS.get(skill, "player"))
		reason = precondition_reason
		source = "llm" if skill == llm_skill else "deterministic"
		break

	if action == "monitor" and rejected:
		reason = f"No executable skill; {rejected[0]}"

	if action == "wake_guard":
		_bb_set(bb, "guard_task", "intercept_player")
	elif action == "patrol_counter":
		_bb_set(bb, "guard_task", "search_counter")
	elif action == "question_player":
		_bb_set(bb, "guard_task", "question_player")
	elif action == "block_exit":
		_bb_set(bb, "guard_task", "block_exit")
	elif action == "chase_player":
		_bb_set(bb, "guard_task", "intercept_player")

	# Post-action emotional pressure adjustments.
	if threat >= 78:
		mem["temper"] = clamp(mem.get("temper", 0) + 2, 0, 100)
	elif threat < 35:
		mem["temper"] = clamp(mem.get("temper", 0) - 1, 0, 100)

	where = _where_from_observation(perception)
	result = "uncertain"
	if action in {"chase_player", "wake_guard", "block_exit"} or intent == "accuse":
		result = "escalated"
	elif action in {"monitor", "patrol_counter"} and confidence < 0.45:
		result = "deescalated"
	what = action if action != "monitor" else intent
	_record_episode(
		mem=mem,
		who="player",
		what=what,
		where=where,
		result=result,
		confidence=confidence,
		observation=perception,
		intent=intent,
	)

	return {
		"action": action,
		"target": target,
		"reason": reason,
		"source": source,
		"llm_proposed_skill": llm_skill if llm_skill else "none",
		"rejected": rejected[:6],
	}


def _stage_guard_consume(
	mem: dict,
	perception: dict[str, Any],
	belief: dict[str, Any],
	skill_stage: dict[str, Any],
) -> dict[str, Any]:
	# Guard agent consumes Barnaby-written blackboard keys and picks guard behavior.
	bb = belief["blackboard"]
	_bb_prune_expired(bb)

	threat_level = float(_bb_get(bb, "threat_level") or 0.0)
	suspect_confidence = float(_bb_get(bb, "suspect_confidence") or 0.0)
	last_seen_pos = _bb_get(bb, "last_seen_pos")
	key_missing = bool(_bb_get(bb, "key_missing"))
	player_visible = bool(_bb_get(bb, "player_visible"))
	guard_task = str(_bb_get(bb, "guard_task") or "idle")
	chosen_action = str(skill_stage.get("action", "monitor"))

	mode = "idle"
	target: Any = "none"
	reason = "No active alert."

	if chosen_action == "chase_player":
		mode = "chase_player"
		target = "player"
		reason = "Barnaby triggered immediate pursuit skill."
	elif key_missing and player_visible:
		mode = "chase_player"
		target = "player"
		reason = "Stolen key confirmed and suspect visible: sprint pursuit."
	elif player_visible and (suspect_confidence >= 0.62 or threat_level >= 68.0):
		mode = "chase_player"
		target = "player"
		reason = "Visible suspect with high confidence/threat."
	elif guard_task == "block_exit" and (key_missing or suspect_confidence >= 0.45):
		mode = "block_exit"
		target = "exit_door"
		reason = "Containment mode: block exit."
	elif guard_task in {"intercept_player", "investigate_last_seen"} and isinstance(last_seen_pos, dict):
		mode = "investigate_last_seen"
		target = last_seen_pos
		reason = "Move to Barnaby's latest seen position."
	elif guard_task == "search_counter":
		mode = "search_counter"
		target = "counter"
		reason = "Search key area behind counter."
	elif guard_task == "question_player" and player_visible:
		mode = "question_player"
		target = "player"
		reason = "Question suspect while visible."
	elif key_missing and isinstance(last_seen_pos, dict):
		mode = "investigate_last_seen"
		target = last_seen_pos
		reason = "Fallback search due to missing key."

	if mode in {"chase_player", "block_exit"}:
		_bb_set(bb, "guard_task", mode)
	elif mode == "idle" and not key_missing:
		_bb_set(bb, "guard_task", "idle", ttl_seconds=1.0)

	return {
		"mode": mode,
		"target": target,
		"reason": reason,
		"threat_level": round(threat_level, 1),
		"suspect_confidence": round(suspect_confidence, 3),
		"player_visible": player_visible,
		"key_missing": key_missing,
	}


def apply_decision_pipeline(mem: dict, obs: dict[str, Any]) -> dict[str, Any]:
	# Explicit multi-stage pipeline:
	# Perception -> Belief Update -> Intent Selection -> Skill Action
	perception = _stage_perception(obs)
	belief = _stage_belief_update(mem, perception)
	intent_stage = _stage_intent_selection(mem, perception, belief)
	belief_for_action = belief.copy()
	belief_for_action["confidence"] = float(intent_stage.get("effective_confidence", belief["confidence"]))
	skill_stage = _stage_skill_action(mem, perception, belief_for_action, intent_stage)
	guard_state = _stage_guard_consume(mem, perception, belief_for_action, skill_stage)

	state = build_state(mem, False)
	intent = str(intent_stage["intent"])
	confidence = float(intent_stage.get("effective_confidence", belief["confidence"]))
	action = str(skill_stage["action"])
	target = str(skill_stage["target"])
	reason = str(skill_stage["reason"])
	skill_source = str(skill_stage.get("source", "deterministic"))
	bb = belief_for_action["blackboard"]
	bb_snapshot = _bb_client_snapshot(bb)
	skill_cooldowns = _skill_cooldowns_remaining(mem)

	return {
		"intent": intent,
		"action": action,
		"target": target,
		"confidence": round(confidence, 3),
		"reason": reason,
		"emotion": state["emotion"],
		"blackboard": bb_snapshot,
		"skill_cooldowns": skill_cooldowns,
		"guard_state": guard_state,
		"brain_state": {
			"suspicion": state["suspicion"],
			"temper": state["temper"],
			"trust": state["trust"],
			"has_stolen": state["has_stolen"],
			"thief_recognized": state["thief_recognized"],
			"last_hood_on": state["last_hood_on"],
			"run_phase": state["run_phase"],
			"run_outcome": state["run_outcome"],
			"run_reason": state["run_reason"],
		},
		"pipeline": {
			"perception": {
				"los": perception["los"],
				"distance": round(float(perception["distance"]), 2),
				"near_key": perception["near_key"],
				"key_missing": perception["key_missing"],
				"hood_on": perception["hood_on"],
			},
			"belief": {
				"suspicion": int(mem.get("suspicion", 0)),
				"temper": int(mem.get("temper", 0)),
				"threat_level": round(float(belief["threat_level"]), 1),
			},
			"intent": {
				"value": intent,
				"before": str(intent_stage.get("intent_before", intent)),
				"proposed": str(intent_stage.get("intent_proposed", intent)),
				"base_value": str(intent_stage.get("base_intent", intent)),
				"memory_adjusted_intent": str(intent_stage.get("memory_adjusted_intent", intent)),
				"base_confidence": float(intent_stage.get("base_confidence", confidence)),
				"memory_adjusted_confidence": float(intent_stage.get("memory_adjusted_confidence", confidence)),
				"smoothed_confidence": float(intent_stage.get("smoothed_confidence", confidence)),
				"effective_confidence": round(confidence, 3),
				"confidence_band": str(intent_stage["confidence_band"]),
				"hysteresis_locked": bool(intent_stage.get("hysteresis_locked", False)),
				"time_since_switch": float(intent_stage.get("time_since_switch", 0.0)),
				"memory_bias": round(float(intent_stage.get("memory_bias", 0.0)), 4),
				"similar_episodes": list(intent_stage.get("similar_episodes", [])),
			},
			"skill_action": {
				"action": action,
				"target": target,
				"source": skill_source,
				"llm_proposed_skill": str(skill_stage.get("llm_proposed_skill", "none")),
				"rejected": list(skill_stage.get("rejected", [])),
				"cooldowns": skill_cooldowns,
			},
			"guard": guard_state,
		},
	}


def apply_intent_to_memory(intent: str, mem: dict) -> dict:
	mem["interactions"] = int(mem.get("interactions", 0)) + 1
	mem["last_intent"] = intent
	# `is_caught` should be evaluated per turn; an old caught flag must not
	# force future non-steal choices (like "charm") into attack/game-over.
	turn_caught = False
	mem["caught"] = False

	if intent == "charm":
		mem["trust"] = clamp(mem.get("trust", 0) + 8, 0, 100)
		mem["temper"] = clamp(mem.get("temper", 0) - 6, 0, 100)
		mem["suspicion"] = clamp(mem.get("suspicion", 0) - 4, 0, 100)
	elif intent == "look_around":
		mem["trust"] = clamp(mem.get("trust", 0) + 5, 0, 100)
		mem["temper"] = clamp(mem.get("temper", 0) - 2, 0, 100)
		mem["suspicion"] = clamp(mem.get("suspicion", 0) - 3, 0, 100)
	elif intent == "bargain":
		mem["trust"] = clamp(mem.get("trust", 0) + 2, 0, 100)
		mem["temper"] = clamp(mem.get("temper", 0) + 1, 0, 100)
		mem["suspicion"] = clamp(mem.get("suspicion", 0) + 2, 0, 100)
	elif intent == "pressure":
		mem["trust"] = clamp(mem.get("trust", 0) - 5, 0, 100)
		mem["temper"] = clamp(mem.get("temper", 0) + 11, 0, 100)
		mem["suspicion"] = clamp(mem.get("suspicion", 0) + 7, 0, 100)
	elif intent == "threaten":
		mem["trust"] = clamp(mem.get("trust", 0) - 12, 0, 100)
		mem["temper"] = clamp(mem.get("temper", 0) + 16, 0, 100)
		mem["suspicion"] = clamp(mem.get("suspicion", 0) + 10, 0, 100)
	elif intent == "apologize":
		mem["trust"] = clamp(mem.get("trust", 0) + 6, 0, 100)
		mem["temper"] = clamp(mem.get("temper", 0) - 8, 0, 100)
		mem["suspicion"] = clamp(mem.get("suspicion", 0) - 3, 0, 100)
	elif intent == "run":
		mem["temper"] = clamp(mem.get("temper", 0) + 3, 0, 100)
		mem["suspicion"] = clamp(mem.get("suspicion", 0) + 5, 0, 100)
	elif intent == "steal":
		turn_caught = True
		mem["has_stolen"] = True
		mem["thief_recognized"] = True
		mem["notoriety"] = clamp(mem.get("notoriety", 0) + 25, 0, 100)
		mem["suspicion"] = 100
		mem["temper"] = 100
		mem["trust"] = clamp(mem.get("trust", 0) - 30, 0, 100)
	else:
		mem["temper"] = clamp(mem.get("temper", 0) + 1, 0, 100)

	return build_state(mem, turn_caught)


def apply_world_event_to_memory(event_type: str, intensity: float, mem: dict, metadata: Optional[dict[str, Any]] = None) -> dict:
	level = max(0.1, float(intensity))
	etype = (event_type or "").strip().lower()
	meta = metadata if isinstance(metadata, dict) else {}
	hood_on = bool(meta.get("hood_on", False))
	bb = _blackboard(mem)

	if etype == "item_thrown":
		item_name = str(meta.get("item_name", "mystery object")).strip()
		classification = classify_thrown_item(item_name)
		label = str(classification.get("label", "trash")).strip().lower()
		confidence = clampf(float(classification.get("confidence", 0.0)), 0.0, 1.0)
		source = str(classification.get("source", "fallback")).strip().lower()

		summary = f"{item_name} -> {label.upper()} ({confidence:.2f}, {source})"
		_bb_set(bb, "last_hf_classification", summary, ttl_seconds=18.0)

		if label == "threat":
			mem["suspicion"] = 100
			mem["temper"] = 100
			mem["run_reason"] = f"Player threw a weapon ({item_name})."
			_bb_set(bb, "threat_level", 100.0)
			_bb_set(bb, "guard_task", "intercept_player")
		elif label == "valuable":
			mem["suspicion"] = clamp(mem.get("suspicion", 0) - 20, 0, 100)
			mem["trust"] = clamp(mem.get("trust", 0) + 15, 0, 100)
			mem["run_phase"] = "distracted"
			mem["run_outcome"] = "active"
			mem["run_reason"] = ""
			_bb_set(bb, "threat_level", clampf(float(mem.get("suspicion", 0)), 0.0, 100.0))
		else:
			mem["temper"] = clamp(mem.get("temper", 0) + 15, 0, 100)
			mem["suspicion"] = clamp(mem.get("suspicion", 0) + 10, 0, 100)
			_bb_set(bb, "threat_level", clampf(float(mem.get("suspicion", 0)), 0.0, 100.0))

	elif etype == "player_seen":
		mem["suspicion"] = clamp(mem.get("suspicion", 0) + int(3 * level), 0, 100)
		mem["temper"] = clamp(mem.get("temper", 0) + int(1 * level), 0, 100)
	elif etype == "player_close":
		mem["suspicion"] = clamp(mem.get("suspicion", 0) + int(4 * level), 0, 100)
		mem["temper"] = clamp(mem.get("temper", 0) + int(2 * level), 0, 100)
	elif etype == "key_touched":
		mem["has_stolen"] = True
		mem["notoriety"] = clamp(mem.get("notoriety", 0) + int(35 * level), 0, 100)
		mem["last_hood_on"] = hood_on
		if not hood_on:
			mem["thief_recognized"] = True
		mem["suspicion"] = clamp(mem.get("suspicion", 0) + int(10 * level), 0, 100)
		mem["temper"] = clamp(mem.get("temper", 0) + int(5 * level), 0, 100)
		mem["trust"] = clamp(mem.get("trust", 0) - int(5 * level), 0, 100)
		mem["run_phase"] = "key_stolen"
		mem["run_outcome"] = "active"
		mem["run_reason"] = ""
	elif etype == "start_visit":
		mem["last_hood_on"] = hood_on
		mem["run_reason"] = ""
		if not mem.get("has_stolen", False):
			mem["run_phase"] = "need_distraction"
			mem["run_outcome"] = "active"
		elif str(mem.get("run_outcome", "active")) != "success":
			mem["run_phase"] = "key_stolen"
			mem["run_outcome"] = "active"
		if mem.get("has_stolen", False):
			# Returning after theft should trigger immediate hostility/pursuit posture.
			recognized = bool(mem.get("thief_recognized", False))
			mem["suspicion"] = max(int(mem.get("suspicion", 0)), 90)
			mem["temper"] = max(int(mem.get("temper", 0)), 88)
			if recognized and not hood_on:
				mem["suspicion"] = max(int(mem.get("suspicion", 0)), 100)
				mem["temper"] = max(int(mem.get("temper", 0)), 100)
				mem["trust"] = clamp(mem.get("trust", 0) - 20, 0, 100)
			elif recognized and hood_on:
				mem["suspicion"] = max(int(mem.get("suspicion", 0)), clamp(mem.get("suspicion", 0) + int(8 * level), 0, 100))
				mem["temper"] = max(int(mem.get("temper", 0)), clamp(mem.get("temper", 0) + int(5 * level), 0, 100))
			else:
				mem["suspicion"] = clamp(mem.get("suspicion", 0) + int(4 * level), 0, 100)
	elif etype == "player_unseen":
		mem["suspicion"] = clamp(mem.get("suspicion", 0) - int(2 * level), 0, 100)
		mem["temper"] = clamp(mem.get("temper", 0) - int(1 * level), 0, 100)
	elif etype == "calm_interaction":
		mem["suspicion"] = clamp(mem.get("suspicion", 0) - int(2 * level), 0, 100)
		mem["trust"] = clamp(mem.get("trust", 0) + int(2 * level), 0, 100)
	elif etype == "distract_started":
		if not mem.get("has_stolen", False):
			mem["run_phase"] = "distracted"
			mem["run_outcome"] = "active"
			mem["run_reason"] = ""
			mem["suspicion"] = clamp(mem.get("suspicion", 0) - int(2 * level), 0, 100)
			mem["trust"] = clamp(mem.get("trust", 0) + int(2 * level), 0, 100)
	elif etype == "distract_expired":
		if not mem.get("has_stolen", False):
			mem["run_phase"] = "need_distraction"
	elif etype == "attempt_key_without_distract":
		mem["suspicion"] = clamp(mem.get("suspicion", 0) + int(6 * level), 0, 100)
		mem["temper"] = clamp(mem.get("temper", 0) + int(4 * level), 0, 100)
		mem["run_reason"] = "Attempted key steal before distraction."
	elif etype == "key_stolen":
		mem["has_stolen"] = True
		mem["run_phase"] = "key_stolen"
		mem["run_outcome"] = "active"
		mem["run_reason"] = ""
	elif etype == "exit_success":
		mem["run_phase"] = "escaped"
		mem["run_outcome"] = "success"
		mem["run_reason"] = ""
	elif etype in {"run_failed", "caught_by_guard"}:
		mem["run_phase"] = "failed"
		mem["run_outcome"] = "failed"
		mem["run_reason"] = str(meta.get("reason", "Run failed."))
	else:
		mem["temper"] = clamp(mem.get("temper", 0) + 1, 0, 100)

	state = build_state(mem, False)
	action_hint = "idle"
	if etype == "start_visit" and state["has_stolen"]:
		action_hint = "alert"
	if state["suspicion"] >= 85 or state["temper"] >= 85:
		action_hint = "alert"
	elif state["suspicion"] >= 55:
		action_hint = "investigate"
	state["action_hint"] = action_hint
	return state


def fallback_barnaby_line(intent: str, emotion: str, is_caught: bool) -> str:
	if is_caught or intent == "steal":
		return "THIEF! Guards, bind this rogue!"

	lines = {
		"pleased": {
			"charm": "A silver tongue, friend. Speak thy offer.",
			"look_around": "Aye, have a look. I mind my stock.",
			"bargain": "For thy courtesy, I shave the price.",
			"pressure": "Steady now. Fair trade needs calm.",
			"threaten": "Bold words dull swift. Mind thy tone.",
			"apologize": "Apology taken. Let us bargain cleanly.",
			"run": "Best not bolt; doors invite suspicion.",
			"talk": "State thy need, and I shall weigh it.",
		},
		"neutral": {
			"charm": "Hail. Coins first, compliments second.",
			"look_around": "Look around, but touch naught unasked.",
			"bargain": "Name thy coin, and we shall see.",
			"pressure": "Push less, and I hear more.",
			"threaten": "Threats sour every honest deal.",
			"apologize": "Very well. Continue with respect.",
			"run": "Running now would raise my alarm.",
			"talk": "Speak plain, traveler. Time is coin.",
		},
		"annoyed": {
			"charm": "Flattery now? Hmph. Be brief.",
			"look_around": "Be quick, and keep in sight.",
			"bargain": "Lower? Not with that attitude.",
			"pressure": "Cease pounding. My patience thins.",
			"threaten": "One more threat, and ye leave.",
			"apologize": "Words mend little. Behave better.",
			"run": "Try running, and I call the guard.",
			"talk": "Quickly. I have sharper customers.",
		},
		"hostile": {
			"charm": "Spare me honeyed lies, cutpurse.",
			"look_around": "Look from afar. Hands to thyself.",
			"bargain": "No bargain. Pay full or begone.",
			"pressure": "Back away, or I call steel.",
			"threaten": "Try me, and regret follows.",
			"apologize": "Apologies do not unring bells.",
			"run": "Run, and every guard hears me roar.",
			"talk": "Enough. My guards grow curious.",
		},
	}
	voice = lines.get(emotion, lines["neutral"])
	return voice.get(intent, voice["talk"])


def llm_rephrase(base_text: str, state: dict, intent: str) -> str:
	if not USE_LLM_REPHRASE:
		return base_text

	memory_context = ""
	if state.get("thief_recognized", False):
		memory_context = "CRITICAL: You recognize this player as a thief from a past encounter. Mention that you remember their face or their past crimes!"

	prompt = (
		"### ROLE: BARNABY, medieval merchant ###\n"
		f"Intent={intent}, Emotion={state['emotion']}, Caught={state['is_caught']}.\n"
		f"{memory_context}\n"
		"Rules:\n"
		"1) <= 12 words.\n"
		"2) Medieval tone.\n"
		"3) No explanations, no meta text.\n"
		f"Draft line: {base_text}\n"
		"Return one polished line only."
	)

	provider = _resolve_llm_provider()
	if provider == "mistral":
		reply = _mistral_rephrase(prompt)
		if reply:
			return reply
	# Fallback path (and default when provider=ollama/auto without key).
	reply = _ollama_rephrase(prompt)
	if reply:
		return reply
	return base_text


def _resolve_llm_provider() -> str:
	if LLM_PROVIDER in {"mistral", "ollama"}:
		return LLM_PROVIDER
	if MISTRAL_API_KEY:
		return "mistral"
	return "ollama"


def _mistral_rephrase(prompt: str) -> str:
	if not MISTRAL_API_KEY:
		return ""
	try:
		r = requests.post(
			MISTRAL_API_URL,
			json={
				"model": MISTRAL_MODEL,
				"messages": [
					{"role": "system", "content": "You are Barnaby, a medieval merchant NPC."},
					{"role": "user", "content": prompt},
				],
				"temperature": 0.35,
				"max_tokens": 28,
			},
			headers={
				"Authorization": f"Bearer {MISTRAL_API_KEY}",
				"Content-Type": "application/json",
			},
			timeout=12,
		)
		payload = r.json()
		choices = payload.get("choices", [])
		if not isinstance(choices, list) or not choices:
			return ""
		message = choices[0].get("message", {})
		content = message.get("content", "")
		if isinstance(content, list):
			content = " ".join(str(part.get("text", "")).strip() for part in content if isinstance(part, dict))
		reply = str(content).strip()
		if 1 <= len(reply.split()) <= 12:
			return reply
	except Exception:
		pass
	return ""


def _ollama_rephrase(prompt: str) -> str:
	try:
		r = requests.post(
			OLLAMA_URL,
			json={
				"model": OLLAMA_MODEL,
				"prompt": prompt,
				"stream": False,
				"options": {"temperature": 0.35, "stop": ["\n", "</s>", "<|"]},
			},
			timeout=12,
		)
		reply = str(r.json().get("response", "")).strip()
		if 1 <= len(reply.split()) <= 12:
			return reply
	except Exception:
		pass
	return ""


def _fallback_mutter_line(suspicion: float, temper: float) -> str:
	if temper >= 72 or suspicion >= 74:
		lines = [
			"Footsteps again. I know it.",
			"Hands off my counter, thief.",
			"Something feels wrong tonight.",
			"Where is that damned key?",
		]
	elif suspicion >= 52:
		lines = [
			"Thought I heard movement.",
			"Did that shelf just creak?",
			"Best check the counter.",
			"Keep your eyes open.",
		]
	else:
		lines = [
			"Quiet shop, uneasy air.",
			"Back to counting coin.",
			"Need to tidy this counter.",
			"Where did I leave it?",
		]
	idx = int(time.time() // 7) % len(lines)
	return lines[idx]


def _mistral_mutter(prompt: str) -> str:
	if not MISTRAL_API_KEY:
		return ""
	try:
		r = requests.post(
			MISTRAL_API_URL,
			json={
				"model": MISTRAL_MODEL,
				"messages": [
					{"role": "system", "content": "You are Barnaby, tense medieval merchant."},
					{"role": "user", "content": prompt},
				],
				"temperature": 0.5,
				"max_tokens": 20,
			},
			headers={
				"Authorization": f"Bearer {MISTRAL_API_KEY}",
				"Content-Type": "application/json",
			},
			timeout=10,
		)
		payload = r.json()
		choices = payload.get("choices", [])
		if not isinstance(choices, list) or not choices:
			return ""
		message = choices[0].get("message", {})
		content = message.get("content", "")
		if isinstance(content, list):
			content = " ".join(str(part.get("text", "")).strip() for part in content if isinstance(part, dict))
		line = str(content).replace("\n", " ").strip()
		line = re.sub(r"\s+", " ", line)
		if len(line.split()) > 8:
			line = " ".join(line.split()[:8])
		if 2 <= len(line.split()) <= 8:
			return line
	except Exception:
		pass
	return ""


def _generate_ambient_mutter(intent: str, suspicion: float, temper: float, current_skill: str, location_hint: str) -> str:
	if intent != "investigate":
		return ""
	prompt = (
		"You are Barnaby, medieval merchant. Mutter to yourself while searching the shop.\n"
		f"Suspicion={int(round(suspicion))}%, Temper={int(round(temper))}%, Skill={current_skill}, Place={location_hint}.\n"
		"Constraints: 3-6 words, tense whisper tone, no quotes, no narration."
	)
	line = _mistral_mutter(prompt)
	if line:
		return line
	return _fallback_mutter_line(suspicion, temper)


def _select_mutter_voice(temper: float) -> tuple[str, str]:
	if temper >= 68 and ELEVENLABS_VOICE_ID_AGITATED:
		return "agitated", ELEVENLABS_VOICE_ID_AGITATED
	if ELEVENLABS_VOICE_ID_CALM:
		return "calm", ELEVENLABS_VOICE_ID_CALM
	if ELEVENLABS_VOICE_ID_AGITATED:
		return "agitated", ELEVENLABS_VOICE_ID_AGITATED
	return "none", ""


def _elevenlabs_tts(text: str, voice_id: str, temper: float) -> tuple[bytes, dict[str, Any]]:
	if not ENABLE_ELEVENLABS_MUTTER:
		return b"", {"status": 0, "error": "tts_disabled", "model": ""}
	if not ELEVENLABS_API_KEY or voice_id == "" or text.strip() == "":
		return b"", {"status": 0, "error": "missing_key_or_voice_or_text", "model": ""}
	stability = 0.56
	if temper >= 68:
		stability = 0.3
	candidate_models: list[str] = []
	for model_name in [ELEVENLABS_MODEL_ID, "eleven_turbo_v2_5", "eleven_multilingual_v2"]:
		clean = str(model_name or "").strip()
		if clean and clean not in candidate_models:
			candidate_models.append(clean)

	last_status = 0
	last_error = "unknown_tts_error"
	last_model = ""
	try:
		for model_id in candidate_models:
			last_model = model_id
			r = requests.post(
				f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}",
				headers={
					"xi-api-key": ELEVENLABS_API_KEY,
					"Content-Type": "application/json",
					"Accept": "audio/mpeg",
				},
				json={
					"text": text,
					"model_id": model_id,
					"output_format": "mp3_44100_128",
					"voice_settings": {
						"stability": stability,
						"similarity_boost": 0.78,
						"use_speaker_boost": True,
					},
				},
				timeout=14,
			)
			last_status = int(r.status_code)
			if last_status == 200 and r.content:
				return r.content, {"status": 200, "error": "", "model": model_id}
			try:
				err_payload = r.json()
			except Exception:
				err_payload = {}
			if isinstance(err_payload, dict):
				if isinstance(err_payload.get("detail"), dict):
					last_error = str(err_payload["detail"].get("message", "elevenlabs_error"))
				else:
					last_error = str(err_payload.get("detail", err_payload.get("message", "elevenlabs_error")))
			else:
				last_error = "elevenlabs_error"
	except Exception as ex:
		last_error = f"request_exception:{type(ex).__name__}"
	return b"", {"status": last_status, "error": last_error, "model": last_model}


def build_menu_options(state: dict) -> list[dict]:
	if state["is_caught"]:
		return [
			{
				"id": "apologize",
				"title": "Plead",
				"prompt": "Drop your hands and beg Barnaby for mercy.",
				"color": "#3aa655",
			},
			{
				"id": "bargain",
				"title": "Bribe",
				"prompt": "Offer extra coin to escape punishment.",
				"color": "#2a7fff",
			},
			{
				"id": "threaten",
				"title": "Defy",
				"prompt": "Defy Barnaby and threaten him to back off.",
				"color": "#d48a00",
			},
			{
				"id": "run",
				"title": "Flee",
				"prompt": "Break away and try to escape the shop.",
				"color": "#c1121f",
			},
		]

	if state["emotion"] == "hostile":
		return [
			{
				"id": "apologize",
				"title": "Apologize",
				"prompt": "Offer a sincere apology and de-escalate.",
				"color": "#3aa655",
			},
			{
				"id": "bargain",
				"title": "Offer Coin",
				"prompt": "Offer more coin for a peaceful deal.",
				"color": "#2a7fff",
			},
			{
				"id": "pressure",
				"title": "Press",
				"prompt": "Press hard for the deal anyway.",
				"color": "#d48a00",
			},
			{
				"id": "look_around",
				"title": "Look Around",
				"prompt": "Say you are only looking around the shop.",
				"color": "#7a8cff",
			},
		]

	return [
		{
			"id": "charm",
			"title": "Charm",
			"prompt": "Offer a respectful greeting and praise the wares.",
			"color": "#3aa655",
		},
		{
			"id": "bargain",
			"title": "Bargain",
			"prompt": "Ask for a fair discount with confidence.",
			"color": "#2a7fff",
		},
		{
			"id": "pressure",
			"title": "Pressure",
			"prompt": "Push Barnaby for better terms urgently.",
			"color": "#d48a00",
		},
		{
			"id": "look_around",
			"title": "Look Around",
			"prompt": "Tell Barnaby you are just having a look around.",
			"color": "#7a8cff",
		},
	]


@app.post("/world_event")
def world_event(request: WorldEventRequest):
	mem = load_memory()
	state = apply_world_event_to_memory(request.event_type, request.intensity, mem, request.metadata)
	save_memory(mem)
	return {
		"ok": True,
		"event_type": request.event_type,
		"brain_state": {
			"suspicion": state["suspicion"],
			"temper": state["temper"],
			"trust": state["trust"],
			"emotion": state["emotion"],
			"has_stolen": state["has_stolen"],
			"thief_recognized": state["thief_recognized"],
			"last_hood_on": state["last_hood_on"],
			"run_phase": state["run_phase"],
			"run_outcome": state["run_outcome"],
			"run_reason": state["run_reason"],
		},
		"action_hint": state.get("action_hint", "idle"),
	}


@app.post("/decide")
def decide(request: DecideRequest):
	mem = load_memory()
	obs = request.observation.dict()
	result = apply_decision_pipeline(mem, obs)
	save_memory(mem)
	return result


@app.post("/chat")
def chat(request: ChatRequest):
	mem = load_memory()
	intent = classify_intent(request.message, request.choice_id)
	state = apply_intent_to_memory(intent, mem)
	save_memory(mem)

	base_line = fallback_barnaby_line(intent, state["emotion"], state["is_caught"])
	text = llm_rephrase(base_line, state, intent)
	voice_profile, voice_id = _select_mutter_voice(float(state.get("temper", 0)))
	audio_bytes, tts_meta = _elevenlabs_tts(text.strip(), voice_id, float(state.get("temper", 0)))
	audio_b64 = base64.b64encode(audio_bytes).decode("ascii") if audio_bytes else ""
	menu_options = build_menu_options(state)

	if wandb_run is not None:
		try:
			wandb.log(
				{
					"intent": intent,
					"emotion": state["emotion"],
					"is_caught": state["is_caught"],
					"trust": state["trust"],
					"suspicion": state["suspicion"],
					"temper": state["temper"],
				}
			)
		except Exception:
			pass

	return {
		"text": text.strip(),
		"emotion": state["emotion"],
		"is_caught": state["is_caught"],
		"voice_profile": voice_profile,
		"audio_format": "mp3",
		"audio_base64": audio_b64,
		"tts_enabled": bool(audio_b64 != ""),
		"tts_status": int(tts_meta.get("status", 0)),
		"tts_model": str(tts_meta.get("model", "")),
		"tts_error": str(tts_meta.get("error", "")),
		"menu_options": menu_options,
		"brain_state": {
			"intent": intent,
			"trust": state["trust"],
			"suspicion": state["suspicion"],
			"temper": state["temper"],
			"interactions": state["interactions"],
			"has_stolen": state["has_stolen"],
			"thief_recognized": state["thief_recognized"],
			"last_hood_on": state["last_hood_on"],
			"run_phase": state["run_phase"],
			"run_outcome": state["run_outcome"],
			"run_reason": state["run_reason"],
		},
	}


@app.post("/ambient_mutter")
def ambient_mutter(request: AmbientMutterRequest):
	intent = str(request.intent or "monitor").strip().lower()
	suspicion = clampf(request.suspicion, 0.0, 100.0)
	temper = clampf(request.temper, 0.0, 100.0)
	current_skill = str(request.current_skill or "monitor").strip().lower()
	location_hint = str(request.location_hint or "counter").strip().lower()

	if intent != "investigate":
		return {
			"ok": True,
			"generated": False,
			"reason": "intent_not_investigate",
			"text": "",
			"audio_base64": "",
			"voice_profile": "none",
		}

	line = _generate_ambient_mutter(intent, suspicion, temper, current_skill, location_hint)
	voice_profile, voice_id = _select_mutter_voice(temper)
	audio_bytes, tts_meta = _elevenlabs_tts(line, voice_id, temper)
	audio_b64 = base64.b64encode(audio_bytes).decode("ascii") if audio_bytes else ""

	return {
		"ok": True,
		"generated": line != "",
		"text": line,
		"voice_profile": voice_profile,
		"audio_format": "mp3",
		"audio_base64": audio_b64,
		"tts_enabled": bool(audio_b64 != ""),
		"tts_status": int(tts_meta.get("status", 0)),
		"tts_model": str(tts_meta.get("model", "")),
		"tts_error": str(tts_meta.get("error", "")),
	}


@app.post("/reset_brain")
def reset_brain():
	mem = reset_memory_to_default()
	state = build_state(mem, False)
	return {
		"ok": True,
		"brain_state": {
			"trust": state["trust"],
			"suspicion": state["suspicion"],
			"temper": state["temper"],
			"has_stolen": state["has_stolen"],
			"thief_recognized": state["thief_recognized"],
			"last_hood_on": state["last_hood_on"],
			"run_phase": state["run_phase"],
			"run_outcome": state["run_outcome"],
			"run_reason": state["run_reason"],
		},
	}


if __name__ == "__main__":
	import uvicorn

	uvicorn.run(app, host="127.0.0.1", port=8000)
