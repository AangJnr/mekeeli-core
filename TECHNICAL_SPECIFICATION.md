# Meekeeli v1 Tech Spec (Offline Local AI Assistant)

## Goal
Build a fully local chat assistant where **all user data stays on-device** by default. The system must support:
- chat with context + history
- multimodal attachments (images, PDFs, docs) for analysis
- local RAG (ingest + retrieve + cite)
- scheduled tasks (one-off + recurring)
- tool/mcp/data-source management with permissions and audit logs
- strict offline enforcement (default)

## Non-goals (v1)
- multi-user accounts (v1 is single-user)
- cloud sync
- “always on the internet” integrations by default

---

## Stack
- UI: Vite + React + TypeScript
- API: Python + FastAPI (async), SSE streaming
- Worker: Python process (same codebase) for scheduled jobs and ingestion
- DB: Postgres (recommended: enable pgvector)
- Model runtime: Ollama (containerized)
- Orchestration: LangGraph for workflows; keep RAG core owned (no hard dependency on LangChain abstractions)

### Default model bundle
- Text: `qwen3-vl:4b`
- Vision: `qwen3-vl:4b`
- Embeddings: `embeddinggemma`

### Model routing rules
- If message contains any **image** attachment: use `qwen2.5vl:7b` to interpret images.
- If message is text-only (or PDFs/docs after text extraction): use `qwen2.5:7b-instruct`.
- For RAG embedding + retrieval: use `bge-m3` only.

---

## High-level architecture

### Services (Docker Compose)
- `mekeeli-ui` (Vite dev server in dev; static build in prod)
- `mekeeli-api` (FastAPI)
- `mekeeli-worker` (runs scheduler + ingestion jobs)
- `db` (Postgres)
- `ollama` (Ollama server)
- `ollama-init` (one-shot: pulls required models into volume before API starts)

### Runtime boundaries
- LLM may propose tool calls, but **must never execute tools directly**.
- Tools are executed only by a **Tool Runner** that enforces:
  - enabled/disabled
  - permission scope
  - schema validation
  - offline/network policy
  - timeouts and sandbox limits

---

## Repo structure (target)

```
/mekeeli-ui
  /src
  /public
  vite.config.ts
  package.json

/mekeeli-api
  /app
    main.py
    /api
      chat.py
      conversations.py
      files.py
      rag.py
      tasks.py
      tools.py
      settings.py
      health.py
    /core
      config.py
      logging.py
      security.py
      offline.py
    /db
      base.py
      session.py
      models.py
      migrations/   (alembic)
    /chat
      orchestrator.py
      prompts.py
      streaming.py
      memory.py
      models.py      (ollama client wrappers)
    /files
      storage.py
      extract_pdf.py
      extract_doc.py
      ocr.py
      image_pipeline.py
    /rag
      chunking.py
      embeddings.py
      ingest.py
      retrieve.py
      citations.py
    /tools
      registry.py
      runner.py
      schemas.py
      builtin/
        filesystem.py
        http.py (disabled by default)
        postgres.py
    /tasks
      scheduler.py
      runner.py
      recurrence.py
    /workflows
      chat_graph.py
      task_graph.py
  Dockerfile
  requirements.txt

/docker-compose.yml
/docker-compose.override.yml
/TECHNICAL_SPECIFICATION.md
```

---

## Offline enforcement

### Policy
- Default mode is **Strict Offline**.
- In Strict Offline:
  - no outbound internet traffic from API/worker containers
  - network tools are disabled
  - only local services are reachable (db, ollama, internal)

### Implementation requirements
1) Docker networking must make outbound traffic impossible by default.
- Use an internal Docker network for stack communication.
- Any “internet-enabled” features require explicitly switching to a different profile or enabling egress.

2) Tool-level enforcement
- Every tool has `requires_network: bool`.
- In Strict Offline, the Tool Runner refuses execution of any network tool.

3) UI transparency
- UI shows a persistent “Offline: ON” indicator.
- Settings page includes:
  - Offline mode toggle (default ON)
  - List of enabled tools and whether they can access network
  - Diagnostics panel

4) Diagnostics endpoint
- `GET /settings/diagnostics` returns:
  - offline mode
  - external endpoints configured (should be empty in offline)
  - enabled tools with network flags
  - model list from Ollama
  - last N tool runs (redacted)

---

## Data model (Postgres)

### Core tables
**workspaces**
- `id (uuid pk)`
- `name text`
- `created_at timestamptz`

**conversations**
- `id uuid pk`
- `workspace_id uuid fk`
- `title text`
- `created_at timestamptz`
- `updated_at timestamptz`
- `last_message_at timestamptz`

**messages**
- `id uuid pk`
- `conversation_id uuid fk`
- `role text` (user|assistant|system|tool)
- `content text`
- `content_json jsonb` (optional structured content)
- `created_at timestamptz`
- `parent_message_id uuid nullable` (for retries/regenerations)
- `attachments jsonb` (list of file ids + metadata)
- `token_usage jsonb` (optional)

**files**
- `id uuid pk`
- `workspace_id uuid fk`
- `conversation_id uuid fk nullable`
- `name text`
- `mime text`
- `size_bytes bigint`
- `storage_path text`
- `extracted_text_path text nullable`
- `metadata jsonb` (pages, dims, etc.)
- `created_at timestamptz`

### RAG tables
**rag_documents**
- `id uuid pk`
- `workspace_id uuid fk`
- `file_id uuid fk`
- `status text` (pending|ready|failed)
- `created_at timestamptz`

**rag_chunks**
- `id uuid pk`
- `workspace_id uuid fk`
- `document_id uuid fk`
- `file_id uuid fk`
- `chunk_index int`
- `text text`
- `page int nullable`
- `char_start int nullable`
- `char_end int nullable`
- `metadata jsonb`
- `embedding vector` (pgvector) OR `embedding float[]` if not using pgvector
- index: ivfflat/hnsw if pgvector enabled

### Tools
**tools**
- `id uuid pk`
- `workspace_id uuid fk`
- `name text`
- `type text` (builtin|mcp|datasource)
- `enabled bool`
- `requires_network bool`
- `config jsonb`
- `created_at timestamptz`

**tool_permissions**
- `id uuid pk`
- `workspace_id uuid fk`
- `tool_id uuid fk`
- `scope text` (global|conversation|session)
- `conversation_id uuid nullable`
- `allowed bool`
- `created_at timestamptz`

**tool_runs**
- `id uuid pk`
- `workspace_id uuid fk`
- `conversation_id uuid fk`
- `tool_id uuid fk`
- `status text` (queued|running|succeeded|failed|blocked)
- `input jsonb`
- `output jsonb`
- `error text nullable`
- `started_at timestamptz`
- `finished_at timestamptz`

### Tasks
**tasks**
- `id uuid pk`
- `workspace_id uuid fk`
- `name text`
- `description text nullable`
- `enabled bool`
- `schedule_type text` (once|cron|rrule)
- `schedule_value text` (ISO datetime or cron string or rrule)
- `timezone text` (default Africa/Accra)
- `payload jsonb` (what to do, which workflow, conversation target)
- `next_run_at timestamptz`
- `created_at timestamptz`

**task_runs**
- `id uuid pk`
- `workspace_id uuid fk`
- `task_id uuid fk`
- `status text` (queued|running|succeeded|failed)
- `logs text`
- `output jsonb`
- `started_at timestamptz`
- `finished_at timestamptz`

### Settings + audit
**settings**
- `workspace_id uuid pk`
- `offline_mode bool default true`
- `default_text_model text`
- `default_vision_model text`
- `default_embed_model text`
- `retention_days int nullable`
- `updated_at timestamptz`

**audit_log**
- `id uuid pk`
- `workspace_id uuid fk`
- `event_type text`
- `details jsonb`
- `created_at timestamptz`

---

## API endpoints (v1)

### Health
- `GET /health` → `{status: "ok"}`

### Conversations
- `GET /workspaces` (v1 can auto-create a single default workspace)
- `GET /conversations?workspace_id=...`
- `POST /conversations` → create
- `GET /conversations/{id}` → metadata
- `GET /conversations/{id}/messages?limit=&cursor=`
- `DELETE /conversations/{id}` → cascade delete messages, attachments references (files may remain if shared)

### Chat
- `POST /chat/send`
  - body: `{workspace_id, conversation_id, content, attachments:[file_id], use_rag?:bool}`
  - returns: `{message_id, assistant_message_id}`
- `GET /chat/stream?conversation_id=&assistant_message_id=...`
  - SSE stream tokens + events (`tool_call_proposed`, `rag_used`, `citations`)
- `POST /chat/cancel` → cancel generation
- `POST /chat/retry` → retries last user message (creates new assistant message with `parent_message_id`)

### Files
- `POST /files/upload` (multipart)
  - returns `{file_id, mime, name}`
- `GET /files/{id}` (download/stream)
- `POST /files/{id}/ingest` (enqueue rag ingestion)
- `GET /files/{id}/status`

### RAG
- `POST /rag/query`
  - body: `{workspace_id, query, top_k}`
  - returns: `{chunks:[{text, file_id, page, chunk_id, score}]}`
- `GET /rag/chunks/{id}`

### Tasks
- `POST /tasks`
  - body: `{name, schedule_type, schedule_value, timezone, payload, enabled}`
- `GET /tasks`
- `POST /tasks/{id}/enable`
- `POST /tasks/{id}/disable`
- `DELETE /tasks/{id}`
- `GET /tasks/{id}/runs`

### Tools
- `GET /tools`
- `POST /tools` (register tool/config)
- `POST /tools/{id}/enable`
- `POST /tools/{id}/disable`
- `POST /tools/{id}/permissions` (grant/revoke)
- `POST /tools/{id}/test` (dry-run validation only)
- `GET /tool-runs?conversation_id=...`

### Settings
- `GET /settings`
- `POST /settings` (update offline mode, defaults, retention)
- `GET /settings/diagnostics`
- `POST /settings/wipe` (wipe workspace data, requires confirmation token in UI)

---

## Multimodal pipeline

### PDFs/docs
- Extract text locally:
  - PDFs: text extraction (pypdf/pdfplumber)
  - scanned PDF/images: OCR (tesseract) if needed
- Store extracted text in file storage and metadata in DB
- Optionally auto-ingest into RAG (async worker job)

### Images
- For analysis:
  - pass image bytes (or path) to `qwen2.5vl:7b` via Ollama
  - obtain structured extraction: `{caption, detected_text, entities, user_relevant_summary}`
- If OCR is enabled, also run OCR and merge results.

---

## RAG implementation (owned core)

### Chunking
- Default chunk size: 800–1200 tokens (or ~3–5k chars) with overlap ~10–15%
- Maintain mapping: chunk → file_id → page → char span

### Ingestion (worker)
1) Load extracted text from file
2) Chunk
3) Embed via `bge-m3`
4) Store chunks + embeddings
5) Mark document ready

### Retrieval
1) Embed query via `bge-m3`
2) Top-k similarity search in pgvector
3) Return chunks with citations
4) Chat orchestrator merges retrieved chunks into “evidence context” and instructs model to cite sources

---

## Tools and permissions

### Tool spec
Each tool has:
- `name`
- `requires_network` (bool)
- `input_schema` (JSON schema)
- `output_schema` (JSON schema)
- `danger_level` (low|medium|high)
- `runner` implementation

### Permission model
Scopes:
- global (applies everywhere)
- conversation (only that conversation)
- session (until app restart / timeout)

Rules:
- High danger tools always require explicit user confirmation per run (even if globally allowed).
- Any tool with `requires_network=true` is blocked when offline mode is ON.

### Tool call protocol (LLM → runner)
LLM must output a structured request:
```json
{
  "tool_name": "filesystem.read",
  "arguments": {"path": "allowed/path/file.txt"},
  "reason": "Need to read file to answer user",
  "danger": "low"
}
```
The runner validates schema + permissions, executes, logs to `tool_runs`, and returns output to the workflow.

---

## Task scheduler

### Worker loop
- Poll DB every N seconds (e.g., 5–15s) for due tasks: `next_run_at <= now() AND enabled=true`
- Lock task row to avoid double execution
- Run task workflow via LangGraph (or direct runner)
- Write `task_runs` record and optionally append a message to target conversation
- Compute next_run_at for recurring tasks

### Schedules
- once: ISO timestamp
- cron: cron string
- rrule: RFC 5545 RRULE

---

## Docker / startup requirements

### `ollama-init`
- Must run before API/worker
- Pull models:
  - `qwen2.5:7b-instruct`
  - `qwen2.5vl:7b`
  - `bge-m3`

### Health checks
- Postgres: `pg_isready`
- Ollama: `ollama list`
- API: `/health`

---

## UI requirements (Vite)

### Core screens
- Chat screen (streaming, cancel, retry, attachments)
- Conversations list + search
- File manager (uploaded files, ingest status, open viewer)
- Tools (registry, enable/disable, permissions, test)
- Tasks (create/edit/disable, run history)
- Settings (offline mode toggle, model selection, wipe/export/import, theme)

### Must-have UX behaviors
- Streaming tokens
- Cancel generation button
- Attachment preview chips
- RAG citations shown as clickable references (file name + page)
- Always-visible offline status indicator

---

## Acceptance criteria checklist (v1)

### Chat + history
- Create conversation, send messages, responses stream
- Context retained across turns
- Conversation history reloads after restart

### Multimodal
- Upload image and ask question about it → answer uses vision pipeline
- Upload PDF and ask question → text extraction + answer
- Ingest PDF into RAG → later query cites relevant chunks

### RAG
- Ingestion creates chunks and embeddings
- Query retrieves top-k with citations
- Chat can use RAG evidence and cite file/page

### Tasks
- Create one-off task that posts result to a conversation at a future time
- Create recurring task (cron/rrule) that runs repeatedly
- Task runs are logged and viewable

### Tools
- Register a tool, enable it, grant permissions
- Tool run logs exist with inputs/outputs
- Dangerous tool requires confirmation
- Network tools blocked in offline mode

### Offline guarantee
- Offline mode is ON by default
- Network tools cannot run in offline mode
- Diagnostics endpoint reports offline mode and tool/network status
- No external endpoints required for core functionality
