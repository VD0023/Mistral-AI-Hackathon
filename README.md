# Living Medieval Engine - Project Bible

## 1. Core Vision
We are not building a chatbot NPC demo. We are building a cognitive multi-agent ecosystem in Godot 4.

Core loop:
- Player is a thief in first-person view.
- Primary objective is to steal a key placed at the back of the shop.
- Merchant (Barnaby) and a nearby guard perceive world state continuously.
- NPC behavior is driven by perception, memory, and state transitions, not static dialogue trees.

## 2. Hackathon Positioning
This project is framed as a scalable AI gameplay system, not a one-off conversation toy.

Competition mapping:
- Best Game (Supercell): Dynamic stealth loop with NPC cooperation and memory.
- Agent Skills (Hugging Face): Reasoned decisions can execute Godot actions (example: `call_for_help()`).
- ElevenLabs Voice: Emotion-tuned real-time voice output.
- Best Vibe (Mistral): Intent/sentiment and state-machine reasoning instead of keyword-only parsing.

Judge hook:
"A living medieval stealth simulation where NPCs remember, coordinate, and react in real time."

## 3. Architecture (Scalable + Low-Bloat)
### Body (Godot)
- Sensors: distance, line-of-sight, hood status, key proximity, interaction state.
- Actuators: movement, animation, tint/emotion visuals, guard wake-up, game-over flow.

### Spine (FastAPI)
- Narrative/state router.
- Stores compact memory vectors and state values in JSON.
- Avoids heavy dialogue/script bloat.

### Brain Tier
- Mistral: decide emotional/state intent and next action.
- Hugging Face Skills: translate intent into executable game actions.
- ElevenLabs: generate emotion-specific voiced lines.

## 4. Gameplay Interaction Standard
The radial menu must be context-triggered, not always visible.

Required interaction flow:
1. Player moves freely in first-person.
2. Player approaches Barnaby.
3. Interaction prompt appears (example: "Press E to interact").
4. Radial menu opens only after interaction input.
5. Choice is sent to Spine; result updates Barnaby behavior and world state.

## 5. Roadmap (One Step at a Time)
Each phase must end in a playable checkpoint.

### Phase 1 - Active Brain (Current, Barnaby)
Goal:
- Barnaby dialog + emotional state loop is playable.

Current status:
- FastAPI connected to Godot.
- Radial options working with backend-driven logic.
- Chase/game-over path exists.

Next sub-steps (sequential):
1. Gate radial behind proximity + interact input (`E`).
2. Add/verify first-person movement loop.
3. Add texture-safe emotion tint polish + optional W&B logging checks.
4. Integrate ElevenLabs response playback.

### Phase 2 - Action Layer (Key + Skill Trigger)
Goal:
- Replace diamond concept with key-at-back gameplay.

Steps:
1. Add key prop and interaction area.
2. Send key-attempt event to Spine.
3. Brain decides whether to execute `call_for_help()`.
4. First checkpoint: skill call is logged even before full guard visuals.

### Phase 3 - Multi-Agent Loop (Guard)
Goal:
- Barnaby influences guard behavior.

Steps:
1. Add guard with `SLEEPING` baseline state.
2. Bind `call_for_help()` to guard state transition `SLEEPING -> ALERT`.
3. Play stand/wake animation and transition to response behavior.

### Phase 4 - Persistence (Hood Mechanic)
Goal:
- Persistent recognition without data bloat.

Rules:
- Hood off + key theft attempt -> persist `THIEF_RECOGNIZED`.
- Return later hood off -> Barnaby recognizes and reacts immediately.
- Return with hood on -> suspicion may rise, but no direct recognition trigger.

## 6. Definition of Success
The final demo must prove:
- NPCs react to world state beyond fixed dialogue.
- Memory persists across sessions in compact state.
- One NPC can trigger another NPC via agent action.
- Player interaction feels like a game system, not just "click radial and chat."

