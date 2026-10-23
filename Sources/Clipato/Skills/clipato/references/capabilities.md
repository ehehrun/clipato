# Capability examples

Inspect `scripts/clipato tools NAME` for the installed app's current schema before
using an example. These are argument objects for `call NAME --input JOB.json`;
all paths are absolute examples and must be replaced with the user's real paths.

## Compression, sizes, and formats

Compress each image to at most 500 KiB, permitting size reduction:

```json
{
  "files": ["/absolute/input/a.png", "/absolute/input/b.heic"],
  "output": "/absolute/output/compressed",
  "format": "jpeg",
  "targetBytes": 512000,
  "allowResizing": true
}
```

Use `image_compress`. `targetBytes` is bytes, not KB; explain whether a requested
KB value uses 1000 or 1024 bytes if the limit matters. Do not claim an impossible
target was achieved if the operation returns an error.

Resize every input to each requested specification using `image_resize`:

```json
{
  "files": ["/absolute/input/a.png"],
  "output": "/absolute/output/sizes",
  "format": "png",
  "sizes": [
    {"width": 1080, "height": 1080, "mode": "crop"},
    {"width": 1280, "height": 720, "mode": "pad"}
  ]
}
```

`fit` preserves aspect ratio within the requested bounds; `pad` fills remaining
space with white; `crop` fills the requested size by cropping. JPEG flattens
transparency onto white; PNG and WebP retain it. `image_convert` accepts `files`,
`output`, `format`, and `quality`, without `sizes`. These operations export new
files without automatic vault import and reject collisions with existing files.

## Four- or nine-grid splitting

For `image_grid`, first choose a square crop when the source is not square:

```json
{
  "files": ["/absolute/input/landscape.jpg"],
  "output": "/absolute/output/grid",
  "divisions": 3,
  "gap": 12,
  "crop": {"x": 240, "y": 0, "width": 1200, "height": 1200}
}
```

Use the actual source dimensions and the user's chosen composition; this example
crop is not a default. Coordinates are source pixels from the top left, and
`width` must equal `height`. `divisions: 2` produces four tiles; `3` produces nine,
ordered left to right and top to bottom. `gap` **removes source pixels** between
tiles to compensate for spacing when posted; direct reassembly omits those
pixels. It does not add blank borders. Omit `tileSize` to use the source crop
without upscaling, capped at 1080 pixels per tile.

## Ordered renaming and detection

For `batch_rename_preview`, followed by `batch_rename` with the same object:

```json
{
  "files": ["/absolute/input/a.jpg", "/absolute/input/b.jpg"],
  "prefix": "Trip_",
  "start": 1,
  "increment": 1,
  "digits": 3
}
```

This order produces `Trip_001.jpg`, then `Trip_002.jpg`. At least two inputs are
required. All must be images or all complete videos; mixed media and keyframe
session directories are unsupported. Do not mix external files with vault files
in one rename job. Preview returns `files`, `filenames`, `destinations`, and
`applied: false`. Vault renaming preserves IDs, tags, and collection membership;
existing destination files are never overwritten.

`files_find_duplicates` and `images_find_similar` each accept `{"files": [...]}`.
Exact detection uses size, header/tail samples, and full SHA-256; hard links to one
file count as one input. It returns `groups` containing `urls`, `fileSize`, and
`sha256`. Similarity returns `matches` with `first`, `second`, `kind`, and `score`,
including resized/compressed copies and one image contained within another.
Neither operation deletes files.

## Capture, recordings, and the vault

Use `displays` to obtain a real `displayID`. Fixed capture and `record` rectangles
are display-local logical points from the top left, unlike grid crop pixels.
Supplying `rect` requires `displayID`. `screenshot` outputs PNG. `record` requires
`duration` in seconds; `keyframes` uses 1/2/4 fps and `video` uses 15/30/60 fps.
Recording output directories must be new or empty. No audio is captured.

`vault_list` returns `images`, matching `paths`, and `total` in insertion order;
paginate with `offset` and `limit` rather than assuming one page is complete.
`recordings_list` paginates sessions and videos separately; request
`includeManifest: true` only when full frame metadata is needed.

Collection operations take existing IDs, not display names. Asset arguments use
`image:UUID`, `session:UUID`, or `video:/absolute/path`. Use the returned fields to
build those references; `collection_items` returns existing Codable asset fields
rather than the same argument-token format. A file path is not an image UUID.

`vault_trash` takes `assets` in this token format and always requires local
confirmation for the selected batch. It moves assets to macOS Trash and removes
their collection references. Removing collection membership with
`collection_remove` or deleting the collection with `collection_delete` leaves
the underlying media in the vault.
