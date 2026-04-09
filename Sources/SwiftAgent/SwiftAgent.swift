// SwiftAgent — On-device Personal AI Agent Framework for iOS
//
// Architecture (inspired by CoPaw):
//
//   ┌──────────────────────────────────────────────┐
//   │                  Agent                        │
//   │  ┌────────────────────────────────────────┐   │
//   │  │         Agent Loop (ReAct)             │   │
//   │  │  message → LLM → parse → tool? → loop  │   │
//   │  └──────────┬─────────────────────────────┘   │
//   │             │                                  │
//   │  ┌──────────▼──────────┐                      │
//   │  │    Skill Router     │                      │
//   │  │  keyword + priority │                      │
//   │  └──┬──────┬──────┬───┘                      │
//   │     │      │      │                           │
//   │  ┌──▼─┐ ┌──▼──┐ ┌─▼──┐                      │
//   │  │Skill│ │Skill│ │Skill│  ← domain modules   │
//   │  │ A   │ │ B   │ │ C  │                      │
//   │  └──┬──┘ └──┬──┘ └─┬──┘                      │
//   │     │       │      │                          │
//   │  ┌──▼───────▼──────▼──┐                      │
//   │  │   Tool Executor    │                      │
//   │  │ confirm → execute  │  ← CoPaw controlled  │
//   │  └────────────────────┘                      │
//   │                                               │
//   │  ┌────────────────────┐                      │
//   │  │  Memory Manager    │                      │
//   │  │  hot/warm/cold     │  ← 3-tier memory     │
//   │  └────────────────────┘                      │
//   │                                               │
//   │  ┌────────────────────┐                      │
//   │  │   LLM Backend      │                      │
//   │  │  Gemma / Apple FM  │  ← swappable         │
//   │  └────────────────────┘                      │
//   └──────────────────────────────────────────────┘
//
// Usage:
//
//   let backend = GemmaBackend()
//   try backend.load(modelPath: "/path/to/gemma.gguf")
//
//   let agent = Agent(llm: backend)
//   await agent.registerSkill(GeneralChatSkill())
//   await agent.registerSkill(MeetingSkill(tools: [mySearchTool]))
//
//   let response = await agent.processMessage("What was discussed in yesterday's meeting?")

// Public API re-exports
public typealias _Agent = Agent
public typealias _AgentMessage = AgentMessage
public typealias _MemoryEntry = MemoryEntry
public typealias _ToolResult = ToolResult
