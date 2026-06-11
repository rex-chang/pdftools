# 2026-06-11 UI refresh

## Context

User provided a screenshot of the Fyne desktop UI and asked for one round of optimization.

## Changes

- Widened the default window to `1080x680` and adjusted the main split to `42/58` so the file queue has enough room.
- Reworked the file queue toolbar into two rows to avoid horizontal overflow in the left panel.
- Added icons, filename truncation, empty-state copy, and toolbar disabled states for invalid actions.
- Fixed the initial selection bug where `selectedID` defaulted to `0` and could remove the first file before a user selected anything.
- Updated the preview panel to show selected file details with a clearer empty state.
- Reworked output settings into a bottom task bar with status, output fields, progress, and the merge action grouped by responsibility.
- Added merge readiness status text such as `已添加 N 个 PDF，可以合并`.
- Rebuilt the local `pdfmerge` binary from the updated source.
- Second pass after screenshot review: moved bottom status text into the wide form area, kept the left side as title-only, and shortened empty-state copy to prevent awkward Chinese wrapping.
- Third pass after screenshot review: made `输出设置` a standalone title row and moved `合并 PDF` into its own action row instead of spanning the form rows.
- Fourth pass after screenshot review: fixed Fyne `Border` layout misuse that compressed the status label into vertical text and stretched the merge button; status and action now use separate rows.

## Verification

- `GOCACHE=/private/tmp/pdfmerge-go-cache /usr/local/go/bin/go build ./...`
- `GOCACHE=/private/tmp/pdfmerge-go-cache /usr/local/go/bin/go vet ./...`
- `GOCACHE=/private/tmp/pdfmerge-go-cache /usr/local/go/bin/go build -o pdfmerge .`

All commands passed. macOS linker emitted the existing warning: `ld: warning: ignoring duplicate libraries: '-lobjc'`.
