# pdfmerge — Go GUI PDF merge tool

Desktop app to merge multiple PDF files via a Fyne GUI. Targets arm64 macOS.

## Project

- **Module**: `pdfmerge` (Go 1.26.4)
- **Stack**: [Fyne v2](https://fyne.io/) GUI + [pdfcpu](https://github.com/pdfcpu/pdfcpu) v0.13 for PDF operations
- **Entry point**: `main.go` — instantiates `ui.NewApp()` and calls `app.Run()`
- **Prebuilt binary**: `pdfmerge` (arm64 Mach-O)
- **Design mockups**: `designs/pdfmerge-ui/` (React HTML prototype, not part of the Go build)

## Commands

| Command | Purpose |
|---|---|
| `go build -o pdfmerge .` | Build the binary |
| `go vet ./...` | Static analysis |
| `go run .` | Run without building |
| `go build ./...` | Verify all packages compile |

No test suite exists yet (`*_test.go` files absent). No linter config or Makefile.

## Architecture

```
main.go          →  ui/app.go         →  pdf/merge.go        → pdfcpu
                     ui/filelist.go       pdf/preview.go
                     ui/preview.go        pdf/errors.go
                     ui/settings.go    →  utils/file.go
```

- **`ui/`** — Fyne GUI layer. Four source files, one per component:
  - `app.go` — `App` struct (owns `Window`, `FileList`, `Preview`, `Settings`), main layout (HSplit at 35/65), drag-drop handler (uses `utils.IsPDF`), merge orchestration with `context.Context` cancellation and `ProgressBarInfinite`.
  - `filelist.go` — `FileList` with add/remove/reorder/sort/clear; dedup on add; "添加文件夹" batch import; each item shows name, size (via `utils.FormatSize`), page count; minimum 56px row height.
  - `preview.go` — `Preview` panel showing selected file info (name, size, pages, full path). All text in Chinese.
  - `settings.go` — `Settings` panel: output filename (auto-named with timestamp), output directory picker, merge button (auto-disabled when <2 files), `ProgressBarInfinite` + `ProgressBar` for merge status.
- **`pdf/`** — PDF processing layer:
  - `merge.go` — `MergePDFs(inputPaths, outputPath)` → `api.MergeCreateFile`.
  - `preview.go` — `GetPageCount` via pdfcpu `api.PageCountFile`.
- **`utils/file.go`** — `IsPDF`, `FileExists`, `GetFileName`, `GetExtension`, `ChangeExtension`, `FormatSize` (human-readable byte formatting).
- **Merge flow**: UI triggers `handleMerge` → creates `context.WithCancel` → shows `ProgressBarInfinite` → calls `pdf.MergePDFs` in goroutine → shows `ProgressBar` at 100% on success / error status on failure. No fake progress.

## Conventions

- **Language**: All user-facing UI text (labels, errors, dialogs) is **Chinese** (e.g. "文件列表", "合并中...", "请至少添加 2 个 PDF 文件"). Code identifiers and comments are English.
- **Naming**: Exported constructors (`NewXxx`), exported types (`FileItem`, `Settings`), callback fields (`OnSelect`, `OnMerge`, `onChange`).
- **Error handling**: `dialog.ShowError` for user errors; `fmt.Errorf` with Chinese messages; goroutine errors set `Settings.StatusLabel` to `"错误: ..."`.
- **GUI pattern**: Widget composition with `container.NewBorder` / `container.NewHBox` / `container.NewVBox`; callback wiring at construction time; no separate controller layer.
- **Async pattern**: Long operations (merge) run in `go func()` with `context.Context` cancellation; UI updates are Fyne-thread-safe. Merge button disabled during operation. `ProgressBarInfinite` for indeterminate progress, `ProgressBar` for completion state.
- **Imports**: Grouped — stdlib, then Fyne, then internal (`pdfmerge/...`). No blank imports or init funcs.

## Notes

- UI audit (2025-06): 22 issues found and fixed — see `AGENTS.md` or git log for details. Key fixes: removed fake progress bar, added context cancellation, dedup on file add, batch folder import, merged button state management, split ratio 35/65, Chinese text consistency, code cleanup in `pdf/errors.go` and `pdf/preview.go`.
