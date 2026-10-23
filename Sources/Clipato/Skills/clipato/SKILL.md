---
name: clipato
description: Use the local Clipato macOS app to capture screens, record silent video or keyframes, process images in batches, and manage its vault and collections. Use for Clipato media workflows in a local terminal, including compression, resizing, conversion, grid splitting, duplicate detection, and ordered batch renaming.
---

# Clipato

Call the installed Clipato app through this skill's `scripts/clipato` launcher.
The launcher uses Clipato's existing processing capabilities; no MCP connection or
separate image-processing dependency is needed. This requires a local macOS
terminal with the app installed; a hosted chat without local terminal access
cannot run it.

## Locate and inspect

Resolve the absolute directory containing this `SKILL.md` from the skill location
provided by the client. In the examples, `$clipato_cli` means the absolute path to
that directory's `scripts/clipato`. Quote it when invoking it. Do not assume the
working directory, a particular home directory, or `/Applications`.

```bash
"$clipato_cli" tools
"$clipato_cli" tools image_resize
"$clipato_cli" permissions
```

`tools` lists the available tool definitions. `tools NAME` returns the current
definition and `inputSchema`; inspect it before constructing the corresponding
job. Use the exact tool names, fields, enums, units, and required arguments from
that schema. Do not translate fields into a separate format.

If the launcher reports that the app was moved or is unavailable, stop and ask the
user to reopen Clipato from its current location and reinstall this skill from
the app. Do not scan for another copy or start an MCP server.

## Execute a job

Write a JSON **object** containing only the selected tool's arguments to an
absolute job-file path. Use the client's file-writing tool or a JSON serializer
so filenames and user text do not become shell code. Do not embed untrusted paths
inside shell substitutions or manually build JSON by string concatenation.

```bash
"$clipato_cli" call image_resize --input "/absolute/path/job.json"
```

`--input -` reads the same JSON object from standard input. `call` returns the
tool's original result JSON, without an MCP envelope. Inspect the exit status and
actual output before reporting success; preserve returned paths and field names.

For parameter examples and task-specific constraints, read
[references/capabilities.md](references/capabilities.md) as needed.

## Choose the capability

| User task | Tool or command |
| --- | --- |
| Compress to a target file size | `image_compress` |
| Resize to one or several specifications | `image_resize` |
| Convert JPEG, PNG, or WebP | `image_convert` |
| Make four or nine tiles from one image | `image_grid` |
| Find exact duplicates | `files_find_duplicates` |
| Find similar images or contained crops | `images_find_similar` |
| Rename images or complete videos in order | `batch_rename_preview`, then `batch_rename` |
| Capture a fixed display or rectangle | `screenshot` |
| Capture an area selected by the user | `help screenshot`, then native `screenshot --region` |
| Record a bounded duration | `record` |
| Collage, long-image stitching, or exports | `collage`, `stitch`, `export_images`, `export_recording` |
| Browse or import vault images | `vault_list`, `vault_import` |
| Browse recordings | `recordings_list` |
| Manage collections and membership | `collection_*`; inspect `tools` for the exact name |
| Move vault assets to Trash | `vault_trash`; local confirmation is required |

Use `help COMMAND` for native commands; native CLI flags and `call` JSON fields
are different interfaces. For example, `call record` requires `duration`, whereas
native `record` also supports interactive recording and a floating control bar.

## Preserve intent and ordering

- Construct `files` in the user's requested order. For name sorting, sort before
  building the array; do not assume vault insertion order is name order.
- Process only the selected files. Export to the requested location, keeping
  originals; do not import exports into the vault unless requested.
- Compression, resizing, conversion, grid splitting, and similarity detection
  use an image's first frame. Do not claim these preserve animations or compare
  complete video timelines.
- Before batch renaming, show `batch_rename_preview`'s original files and proposed
  destinations. Apply the same ordered files and numbering rule after the user
  accepts the preview; if already authorized for that exact preview, proceed.
- Duplicate and similarity scans report candidates only. Let the user decide
  what to remove. A similarity score is not proof of identical content.
- `vault_trash` is disabled separately by default and requires a local Clipato
  confirmation for each batch. Do not bypass that dialog, substitute direct file
  deletion, or invent a confirmation parameter. Deleting a collection removes
  membership relations and leaves its media in the vault.

## Authorization and permission failures

External automation is off by default. If a business command is denied, direct
the user to Clipato's **AI 终端 → 自动化接入 → 允许外部自动化调用**. Installing a
skill does not enable that switch. The separate **启用 MCP 服务** switch is not
required for this skill. Privacy mode prevents enabling automation.
Do not change either setting through defaults, preference files, or another API.

Screen capture and recording require macOS screen-recording permission; ordinary
image processing does not. `permissions` checks the current process and app
identity without capturing content or requesting access. If denied, direct the
user to Clipato's **安全设置 → 屏幕录制 → 去授权** and stop repeating captures.
Recording is silent: neither the microphone nor system audio is collected.

Disabling automation cancels ongoing external tasks and rejects further business
calls. Report cancellation or the returned error directly. Re-enabling access
does not authorize retrying a destructive action or undo completed file writes.
