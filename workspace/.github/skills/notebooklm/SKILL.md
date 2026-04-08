---
name: notebooklm
description: Use Google NotebookLM through the web browser to create notebooks, add sources, ask questions, generate audio summaries, and research topics. Use when the user mentions NotebookLM, wants to analyze documents, create an AI podcast, or needs research assistance.
---

# NotebookLM via Browser

Use Google NotebookLM (notebooklm.google.com) through the web browser to analyze documents, ask questions, and generate audio summaries.

## Getting Started

```
web_navigate url=https://notebooklm.google.com
web_snapshot
```

If not logged in, you'll need to sign in with Google first.

## Create a Notebook

```
web_snapshot
# Find "New notebook" or "+" button
web_click ref=rN
web_snapshot
```

## Add Sources

NotebookLM works by analyzing sources you add:

```
# After creating or opening a notebook:
web_snapshot
# Find "Add source" button
web_click ref=rN
web_snapshot

# Options: paste a URL, upload a file, or paste text
# For URL:
web_click ref=rN  # "Website" option
web_type ref=rN text=https://example.com/article
web_click ref=rN  # Submit/Add button
```

## Ask Questions

Once sources are added, use the chat to ask questions:

```
web_snapshot
# Find the chat input
web_type ref=rN text=What are the key findings?
web_click ref=rN  # Send button
web_snapshot
# Read the AI response
```

## Generate Audio Summary

NotebookLM can create AI podcast-style audio summaries:

```
web_snapshot
# Find "Audio Overview" or "Studio" section
web_click ref=rN
# Click "Generate" or similar
web_click ref=rN
# Wait for generation (may take a few minutes)
web_snapshot
```

## Tips

1. Add multiple sources for better analysis
2. Sources can be: websites, PDFs, Google Docs, pasted text
3. Audio summaries are great for learning on the go
4. Ask specific questions rather than vague ones
5. NotebookLM cites its sources in responses
