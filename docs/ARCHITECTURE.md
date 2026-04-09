# SwiftAgent Architecture

## Overview

SwiftAgent is an on-device personal AI agent framework for iOS. Architecture inspired by CoPaw (Alibaba) and OpenClaw.

```
┌─────────────────────────────────────────────────────┐
│                      Agent                           │
│                                                      │
│  ┌───────────┐                                       │
│  │   Soul    │  Identity, personality, boundaries    │
│  │ (SOUL.md) │  Injected into every prompt           │
│  └─────┬─────┘                                       │
│        │                                             │
│  ┌─────▼─────────────────────────────────┐           │
│  │         Agent Loop (ReAct)            │           │
│  │  1. Build prompt (soul + memory +     │           │
│  │     skills + tools + history)         │           │
│  │  2. Check if planning needed          │           │
│  │  3. LLM generate                     │           │
│  │  4. Parse: tool_call → execute → loop │           │
│  │         final_answer → return         │           │
│  └──┬──────────┬──────────┬─────────────┘           │
│     │          │          │                          │
│  ┌──▼──┐  ┌───▼────┐  ┌──▼─────────┐               │
│  │Plan-│  │ Skill  │  │  Memory    │               │
│  │ner  │  │ Router │  │  Manager   │               │
│  └──┬──┘  └───┬────┘  └──┬─────────┘               │
│     │         │          │                          │
│  ┌──▼──┐  ┌───▼──┐  ┌───▼───────────────┐          │
│  │Steps│  │Skills│  │ Hot │ Warm │ Cold  │          │
│  │1→2→3│  │A,B,C │  │ctx  │facts │raw   │          │
│  └─────┘  └──┬───┘  └───────────────────┘          │
│              │                                      │
│  ┌───────────▼────────────────────┐                 │
│  │      Tool Executor             │                 │
│  │  Confirm gate → Execute → Fail │                 │
│  └────────────────────────────────┘                 │
│                                                      │
│  ┌────────────────────────────────┐                 │
│  │       LLM Backend              │                 │
│  │  GemmaBackend │ AppleFMBackend │                 │
│  └────────────────────────────────┘                 │
└─────────────────────────────────────────────────────┘
```

## Components

### Soul (from OpenClaw SOUL.md + CoPaw PROFILE.md)

The Soul defines WHO the agent is. It is injected into every prompt.

```swift
struct Soul {
    var identity: Identity      // name, role, traits, description
    var style: CommunicationStyle  // language, formality, verbosity
    var values: [String]        // decision-making principles
    var boundaries: [String]    // HARD limits (never violate)
    var knowledgeAreas: [String]  // expertise domains
    var customInstructions: String  // freeform additions
}
```

**Key principle**: "It reads itself into being" — personality is configuration, not code. Change the Soul JSON file → agent behavior changes immediately. No recompilation needed.

**Rendering**: `soul.renderSystemPrompt()` produces structured text:
```
You are Gemma, a trợ lý AI cá nhân chạy trên thiết bị.
Personality: thông minh, ngắn gọn, thân thiện, chính xác.

COMMUNICATION STYLE:
- Primary language: vi
- Formality: neutral
- Length: concise

VALUES & PRINCIPLES:
- Chính xác hơn là nhanh...

BOUNDARIES (NEVER VIOLATE):
- KHÔNG bao giờ bịa thông tin cuộc họp...
```

### Planner (from CoPaw task decomposition)

Complex requests are decomposed into steps before execution.

**Decision**: `needsPlanning()` uses heuristics (keywords like "và", "rồi", "tất cả", multiple questions). No LLM call needed.

**Plan structure**:
```swift
Plan
├── goal: "Tóm tắt họp hôm qua và tạo reminder"
├── steps:
│   ├── Step 0: thought="Cần tìm cuộc họp" action="search" tool="search_meetings"
│   ├── Step 1: thought="Lấy action items" action="extract" tool="get_action_items"
│   └── Step 2: thought="Tạo nhắc nhở" action="create" tool="create_reminder"
└── status: .executing
```

**Execution**: Steps run sequentially. If a step fails → skip (not abort). Final status: `.completed`, `.partiallyCompleted`, or `.failed`.

**Summarization**: After execution, LLM synthesizes step results into a natural language answer.

### Memory (from CoPaw ReMe + Mem0)

Three-tier memory with extraction, decay, and compression.

#### Tiers

| Tier | Storage | Content | Managed by |
|---|---|---|---|
| Hot | Prompt context window | Current conversation | Agent (auto-trim to 1/3 context) |
| Warm | MemoryStore (in-memory or persistent) | Extracted facts, preferences, entities | MemoryManager |
| Cold | Host app (SwiftData) | Raw transcripts, full history | Host app |

#### User Profile (CoPaw PROFILE.md)

Accumulated user preferences, identity, work context. Categories:
- `identity`: "Tên tôi là Khoa", "Tôi là developer"
- `preferences`: "Tôi thích cà phê", "Prefer dark mode"
- `work_context`: "Tôi làm việc tại startup"

Profile is injected into prompts for personalization.

#### Memory Lifecycle

1. **Extract**: After each conversation turn, extract facts/preferences from user messages
2. **Store**: Save to warm tier with relevance score
3. **Retrieve**: For each new message, query warm tier for relevant context
4. **Decay**: Daily, reduce relevance scores. Unused memories with low scores are forgotten
5. **Compact**: When warm tier exceeds threshold, remove least relevant entries

### Skills

Domain-specific modules. Each skill provides:
- Tools (executable functions)
- System prompt extension (domain context)
- Trigger keywords (for routing)
- Priority (for conflict resolution)
- Lifecycle hooks (onActivate/onDeactivate)

**Built-in skills**: GeneralChat, Meeting, Reminder

**Routing**: SkillRouter matches user message keywords against registered skills. Best-matching skills are activated for the turn.

### Tools

Stateless functions with:
- Name + description (for LLM)
- JSON parameter schema
- `execute(parameters:) async throws -> ToolResult`
- Confirmation flag (CoPaw controllable pattern)

**Confirmation gate**: Tools marked `requiresConfirmation = true` require user approval via `onToolConfirmation` callback before execution.

**Built-in tools**: DateTime, Calculator, TextSearch

### LLM Backend

Pluggable inference via `LLMBackend` protocol:
- `generate(prompt:maxTokens:temperature:)` — blocking
- `generateStream(prompt:maxTokens:temperature:)` — async stream
- `countTokens(_:)` — for context management
- `isReady` / `contextSize` — state

**Implementations**:
- `GemmaBackend` — Gemma 4 via llama.cpp (production ready)
- Future: `AppleFMBackend` — Apple Foundation Models (iOS 26)

## CoPaw Design Patterns Applied

| CoPaw Pattern | SwiftAgent Implementation |
|---|---|
| **Controllable** | `onToolConfirmation` callback, `requiresConfirmation` per tool |
| **Stable** | Try/catch on tool execution, plan step skip on failure, max step limit |
| **Memory (ReMe)** | 3-tier with extraction, decay, compression, user profile |
| **PROFILE.md** | `UserProfile` with categorized entries, auto-updated from conversation |
| **Skill Pool** | Two-layer: SkillRouter (routing) + AgentSkill (execution) |
| **Security** | Soul boundaries, tool confirmation, max step limits |

## Data Flow

```
User message
    │
    ▼
Skill Router → select active skills
    │
    ▼
Check: needsPlanning()?
    │
    ├── Yes → Planner.generatePlan() → execute steps → summarize
    │
    └── No → build prompt:
                 Soul.renderSystemPrompt()
               + Memory.buildContext()
               + Skill.systemPromptExtension
               + Tool definitions
               + Conversation history (trimmed)
               + "Assistant: "
                    │
                    ▼
              LLM generate
                    │
                    ├── <tool_call> → confirm? → execute → loop
                    │
                    └── final answer → return to user
                              │
                              ▼
                    Async: Memory.extractAndStore()
```
