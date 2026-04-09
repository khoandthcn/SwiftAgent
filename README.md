# SwiftAgent

On-device Personal AI Agent framework for iOS, built in Swift.

Runs 100% offline using Gemma 4 via llama.cpp. Designed for building personal AI assistants with skills, tools, and persistent memory on iPhone.

## Architecture

Inspired by [CoPaw](https://github.com/copaw) (controllable + stable agent) and adapted for on-device constraints.

```
┌──────────────────────────────────────────┐
│                 Agent                     │
│                                           │
│  Agent Loop (ReAct)                       │
│  message → LLM → parse → tool? → loop    │
│         │                                 │
│  Skill Router                             │
│  keyword + priority matching              │
│     │         │         │                 │
│  ┌──▼──┐  ┌───▼───┐  ┌──▼──┐            │
│  │Skill│  │Skill  │  │Skill│  domains    │
│  │Chat │  │Meeting│  │Cal  │             │
│  └──┬──┘  └───┬───┘  └──┬──┘            │
│     └─────────┼─────────┘                │
│  Tool Executor (confirm → execute)        │
│                                           │
│  Memory Manager (hot / warm / cold)       │
│                                           │
│  LLM Backend (Gemma 4 / Apple FM)         │
└──────────────────────────────────────────┘
```

## Key Concepts

### Skills
Domain-specific capabilities with their own tools and prompt context. Skills are the primary unit of extensibility.

```swift
struct WeatherSkill: AgentSkill {
    let id = "weather"
    let name = "Weather"
    let description = "Get weather forecasts"
    let tools: [any AgentTool] = [WeatherTool()]
    let triggerKeywords = ["weather", "thời tiết", "rain", "mưa"]
}
```

### Tools
Stateless functions the agent can invoke. Tools receive JSON parameters and return results.

```swift
struct WeatherTool: AgentTool {
    let id = "get_weather"
    let name = "get_weather"
    let description = "Get weather for a location"
    let parametersSchema = """
    {"location": "string"}
    """
    let requiresConfirmation = false

    func execute(parameters: String) async throws -> ToolResult {
        // ... fetch weather ...
        return .success("Hanoi: 28°C, sunny")
    }
}
```

### Memory (3 tiers)
| Tier | Storage | Content | Latency |
|---|---|---|---|
| Hot | Context window | Current conversation | 0ms |
| Warm | MemoryStore | Extracted facts, preferences | ~5ms |
| Cold | Host app (SwiftData) | Raw transcripts, full history | ~20ms |

### Controllable Execution (CoPaw pattern)
Dangerous tools require user confirmation before execution:

```swift
agent.onToolConfirmation = { toolName, params in
    // Show UI confirmation dialog
    return await showConfirmation("Allow \(toolName)?")
}
```

## Quick Start

```swift
import SwiftAgent

// 1. Create LLM backend
let backend = GemmaBackend()
try backend.load(modelPath: "/path/to/gemma-4-e2b.gguf")

// 2. Create agent
let agent = Agent(llm: backend)

// 3. Register skills
await agent.registerSkill(GeneralChatSkill())
await agent.registerSkill(MeetingSkill(tools: [mySearchTool]))
await agent.registerSkill(ReminderSkill(tools: [myReminderTool]))

// 4. Chat
let response = await agent.processMessage("Cuộc họp hôm qua bàn gì?")
print(response)
```

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/khoandthcn/SwiftAgent", from: "0.1.0")
]
```

## Requirements

- iOS 17.0+ / macOS 14.0+
- Swift 6.0
- Gemma 4 GGUF model file (for GemmaBackend)

## Project Structure

```
Sources/SwiftAgent/
├── Core/
│   ├── AgentProtocols.swift   # LLMBackend, AgentTool, AgentSkill, MemoryStore
│   ├── Agent.swift            # Main agent loop with skill routing
│   └── SkillRouter.swift      # Keyword-based skill selection
├── LLM/
│   └── GemmaBackend.swift     # Gemma 4 via llama.cpp
├── Memory/
│   ├── MemoryManager.swift    # 3-tier memory orchestration
│   └── InMemoryStore.swift    # Simple in-memory store
├── Skills/
│   └── BuiltInSkills.swift    # GeneralChat, Meeting, Reminder skills
└── Tools/
    └── BuiltInTools.swift     # DateTime, Calculator, TextSearch tools
```

## Roadmap

- [ ] Gemma 4 native tool calling tokens (structured function calling)
- [ ] Apple Foundation Models backend (iOS 26)
- [ ] Vector store integration (ObjectBox / VecturaKit) for semantic memory
- [ ] RAG pipeline for meeting transcript search
- [ ] EventKit tools (Calendar, Reminders)
- [ ] Contacts framework integration
- [ ] Multi-turn tool calling with context preservation
- [ ] Streaming agent responses
- [ ] Conversation persistence (SQLite)

## License

Apache License 2.0
