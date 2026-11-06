"""Command-line RAG chat backed by a local Ollama instance."""

from __future__ import annotations

import os
import sys
from pathlib import Path

import numpy as np
import requests

OLLAMA_URL = os.getenv("OLLAMA_URL", "http://localhost:11434").rstrip("/")
EMBED_MODEL = os.getenv("EMBED_MODEL", "nomic-embed-text")
CHAT_MODEL = os.getenv("CHAT_MODEL", "qwen3:4b-instruct")
DOCS_DIR = Path(os.getenv("DOCS_DIR", "docs"))
TOP_K = int(os.getenv("TOP_K", "3"))
REQUEST_TIMEOUT = 120


def load_chunks(docs_dir: Path) -> list[str]:
    """Split every Markdown file in *docs_dir* into paragraph-sized chunks."""
    chunks: list[str] = []
    for file in sorted(docs_dir.glob("*.md")):
        text = file.read_text(encoding="utf-8")
        chunks.extend(part.strip() for part in text.split("\n\n") if part.strip())
    return chunks


def embed(texts: list[str]) -> np.ndarray:
    """Return one embedding vector per input text."""
    try:
        response = requests.post(
            f"{OLLAMA_URL}/api/embed",
            json={"model": EMBED_MODEL, "input": texts},
            timeout=REQUEST_TIMEOUT,
        )
        response.raise_for_status()
    except requests.RequestException as exc:
        raise RuntimeError(f"Could not reach Ollama at {OLLAMA_URL}: {exc}") from exc

    embeddings = response.json().get("embeddings")
    if not embeddings:
        raise RuntimeError("Ollama returned no embeddings. Is the embedding model pulled?")
    return np.asarray(embeddings, dtype=float)


def retrieve(
    question: str, chunks: list[str], chunk_vectors: np.ndarray, k: int = TOP_K
) -> list[str]:
    """Return the *k* chunks most similar to *question* by cosine similarity."""
    query = embed([question])[0]
    scores = chunk_vectors @ query / (
        np.linalg.norm(chunk_vectors, axis=1) * np.linalg.norm(query)
    )
    return [chunks[i] for i in np.argsort(scores)[::-1][:k]]


def ask_llm(prompt: str) -> str:
    """Send a single prompt to the chat model and return its answer."""
    try:
        response = requests.post(
            f"{OLLAMA_URL}/api/chat",
            json={
                "model": CHAT_MODEL,
                "stream": False,
                "messages": [{"role": "user", "content": prompt}],
            },
            timeout=REQUEST_TIMEOUT,
        )
        response.raise_for_status()
    except requests.RequestException as exc:
        raise RuntimeError(f"Could not reach Ollama at {OLLAMA_URL}: {exc}") from exc

    return response.json()["message"]["content"]


def build_prompt(question: str, context: str) -> str:
    return f"""Answer the question using ONLY the context below.
If the answer isn't in the context, say "I don't know".

Context:
{context}

Question: {question}"""


def main() -> int:
    if not DOCS_DIR.is_dir():
        print(f"Docs directory not found: {DOCS_DIR}", file=sys.stderr)
        return 1

    chunks = load_chunks(DOCS_DIR)
    if not chunks:
        print(f"No Markdown files with content found in {DOCS_DIR}", file=sys.stderr)
        return 1

    try:
        chunk_vectors = embed(chunks)
    except RuntimeError as exc:
        print(exc, file=sys.stderr)
        return 1

    print(f"Indexed {len(chunks)} chunks from {DOCS_DIR}")
    print("Type a question, or /exit to quit.\n")

    while True:
        try:
            question = input("Ask: ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return 0

        if not question:
            continue
        if question.lower() in {"/exit", "/quit", "exit", "quit"}:
            return 0

        try:
            context = "\n\n".join(retrieve(question, chunks, chunk_vectors))
            answer = ask_llm(build_prompt(question, context))
        except RuntimeError as exc:
            print(exc, file=sys.stderr)
            continue

        print(f"\n{answer}\n")


if __name__ == "__main__":
    raise SystemExit(main())
