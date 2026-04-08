---
name: mermaid-diagrams
description: Create diagrams using Mermaid syntax. Use when the user wants to visualize, diagram, chart, or map out a system, flow, process, architecture, database schema, or relationships. Supports flowcharts, sequence diagrams, class diagrams, ER diagrams, state diagrams, and more.
---

# Mermaid Diagrams

Create diagrams using simple text syntax. Mermaid code renders into visual diagrams.

## How to Use

Write Mermaid code inside a fenced code block:

````markdown
```mermaid
flowchart LR
    A[Start] --> B[Process] --> C[End]
```
````

Save diagrams in markdown files in the project. Mermaid code blocks render as visual diagrams in the chat and in markdown preview.

**Live preview:** You can also render diagrams in the browser via web_agent:
```
web_navigate url=https://mermaid.live
```
Paste your Mermaid code in the editor to see it visually and export as PNG/SVG.

## Common Diagram Types

### Flowchart

```mermaid
flowchart TD
    A[User Opens App] --> B{Logged In?}
    B -- Yes --> C[Show Home]
    B -- No --> D[Show Login]
    D --> E[Enter Credentials]
    E --> F{Valid?}
    F -- Yes --> C
    F -- No --> D
```

Direction: `TD` (top-down), `LR` (left-right), `BT` (bottom-top), `RL` (right-left)

### Sequence Diagram

```mermaid
sequenceDiagram
    User->>App: Tap Login
    App->>Server: Send credentials
    Server-->>App: Return token
    App-->>User: Show home screen
```

### Class Diagram

```mermaid
classDiagram
    class User {
        +String name
        +String email
        +login()
    }
    class Post {
        +String title
        +String content
        +publish()
    }
    User "1" --> "*" Post : creates
```

### Entity Relationship (Database)

```mermaid
erDiagram
    USER ||--o{ POST : writes
    POST ||--o{ COMMENT : has
    USER ||--o{ COMMENT : writes
    
    USER {
        int id PK
        string name
        string email
    }
    POST {
        int id PK
        string title
        string content
        int author_id FK
    }
```

### State Diagram

```mermaid
stateDiagram-v2
    [*] --> Draft
    Draft --> Review : Submit
    Review --> Published : Approve
    Review --> Draft : Reject
    Published --> [*]
```

### Pie Chart

```mermaid
pie title App Usage
    "Home" : 45
    "Search" : 25
    "Profile" : 20
    "Settings" : 10
```

## Node Shapes

- `[Text]` — rectangle
- `(Text)` — rounded
- `{Text}` — diamond (decision)
- `([Text])` — stadium
- `[[Text]]` — subroutine
- `((Text))` — circle

## Arrow Types

- `-->` — solid arrow
- `-.->` — dotted arrow
- `==>` — thick arrow
- `-->>` — solid arrow with open head
- `-- text -->` — labeled arrow

## Tips

1. Keep diagrams simple — focus on key relationships
2. Use flowcharts for processes and user flows
3. Use sequence diagrams for API/interaction flows
4. Use ER diagrams for database design
5. Use class diagrams for object/data modeling
