# Byte Bistro RAG

A small, local retrieval-augmented generation (RAG) chat app. It indexes the Markdown
files in [`docs/`](docs), retrieves the paragraphs most relevant to your question with
embeddings, and asks a local Ollama model to answer using **only** that context.

The bundled example corpus is the **Byte Bistro** employee handbook, so you can ask
things like:

- *What is the Wi-Fi password policy?*
- *Who do I call if the espresso machine breaks?*
- *How much PTO do I earn?*
- *What is in the Stack Overflow Latte?*

## How it works

1. Every `*.md` file in `docs/` is split into paragraphs (chunks).
2. Each chunk is embedded with `nomic-embed-text` via Ollama.
3. Your question is embedded too, and the top `TOP_K` chunks (3 by default) are selected
   by cosine similarity.
4. Those chunks are inserted into a prompt for `qwen3:4b-instruct`, which is instructed
   to answer only from the supplied context and to say *"I don't know"* otherwise.

Everything runs locally. No API keys or cloud services are required.

## Requirements

- Python **3.13+**
- [uv](https://docs.astral.sh/uv/)
- [Ollama](https://ollama.com/) running locally

## Quick start

```powershell
# 1. Install dependencies
uv sync

# 2. Pull the models (once)
ollama pull nomic-embed-text
ollama pull qwen3:4b-instruct

# 3. Make sure Ollama is running
ollama serve

# 4. Start chatting (run from the repository root)
uv run byte-bistro-rag
```

Example session:

```text
Indexed 11 chunks from docs
Type a question, or /exit to quit.

Ask: What is the Wi-Fi password?
The Wi-Fi network is called ByteGuest, and the password changes every Monday.
Staff can find the current password on the whiteboard behind the espresso machine.

Ask: /exit
```

## Adding your own documents

Drop any `.md` file into `docs/` and restart the app. Files are read in alphabetical
order and split on blank lines, so keep each paragraph focused on one topic for the
best retrieval results.

To use a different folder, set `DOCS_DIR`:

```powershell
$env:DOCS_DIR = "C:\path\to\notes"
uv run byte-bistro-rag
```

## Configuration

All settings are optional environment variables.

| Variable       | Default                   | Description                                      |
| -------------- | ------------------------- | ------------------------------------------------ |
| `OLLAMA_URL`   | `http://localhost:11434`  | Base URL of the Ollama API                      |
| `EMBED_MODEL`  | `nomic-embed-text`        | Model used to embed documents and questions     |
| `CHAT_MODEL`   | `qwen3:4b-instruct`       | Model used to generate answers                  |
| `DOCS_DIR`     | `docs`                    | Folder containing the Markdown source documents |
| `TOP_K`        | `3`                       | Number of chunks retrieved per question         |

For example:

```powershell
$env:CHAT_MODEL = "llama3.2:3b"
$env:TOP_K = "5"
uv run byte-bistro-rag
```

## Project structure

```text
.
├── docs/
│   └── handbook.md           # Example corpus: Byte Bistro employee handbook
├── src/
│   └── byte_bistro_rag/
│       ├── __init__.py
│       └── cli.py            # Indexing, retrieval, prompting, and chat loop
├── Fix-BrokenVenv.ps1        # Helper for repairing Windows virtualenv launchers
├── pyproject.toml
└── README.md
```

## Troubleshooting

- **`Could not reach Ollama`** — Start Ollama with `ollama serve` and confirm
  `OLLAMA_URL` points to it.
- **`Ollama returned no embeddings`** — Pull the embedding model:
  `ollama pull nomic-embed-text`.
- **Answers ignore the handbook** — The model is small and local. Try a larger chat
  model or lower `TOP_K` to give it less distracting context.
- **Windows virtualenv launcher errors** — Run
  `powershell -ExecutionPolicy Bypass -File .\Fix-BrokenVenv.ps1`.

## Limitations

This is a demo, not a production search system: the index is rebuilt in memory on
every start, chunking is paragraph-based, and there is no conversation memory. Each
question is answered independently.
