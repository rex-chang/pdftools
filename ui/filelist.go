package ui

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/layout"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"

	"pdfmerge/pdf"
	"pdfmerge/utils"
)

type FileItem struct {
	Path      string
	Name      string
	Size      int64
	PageCount int
}

type FileList struct {
	Items      []*FileItem
	List       *widget.List
	EmptyState *fyne.Container
	OnSelect   func(*FileItem)
	Window     fyne.Window
	onChange   func()
	selectedID int
	removeBtn  *widget.Button
	upBtn      *widget.Button
	downBtn    *widget.Button
	sortBtn    *widget.Button
	clearBtn   *widget.Button
}

func NewFileList(w fyne.Window, onChange func()) *FileList {
	fl := &FileList{
		Window:     w,
		onChange:   onChange,
		selectedID: -1,
	}
	fl.List = widget.NewList(
		func() int { return len(fl.Items) },
		func() fyne.CanvasObject {
			icon := widget.NewIcon(theme.FileTextIcon())
			nameLabel := widget.NewLabel("filename.pdf")
			nameLabel.TextStyle = fyne.TextStyle{Bold: true}
			nameLabel.Truncation = fyne.TextTruncateEllipsis
			metaLabel := widget.NewLabel("1.2 MB · 3 页")
			metaLabel.TextStyle = fyne.TextStyle{}
			box := container.NewHBox(icon, container.NewVBox(nameLabel, metaLabel))
			box.Resize(fyne.NewSize(0, 56))
			return box
		},
		func(id widget.ListItemID, obj fyne.CanvasObject) {
			if id < len(fl.Items) {
				item := fl.Items[id]
				box := obj.(*fyne.Container)
				content := box.Objects[1].(*fyne.Container)
				content.Objects[0].(*widget.Label).SetText(item.Name)
				content.Objects[1].(*widget.Label).SetText(fmt.Sprintf("%s  ·  %d 页", utils.FormatSize(item.Size), item.PageCount))
			}
		},
	)
	fl.List.OnSelected = func(id widget.ListItemID) {
		fl.selectedID = int(id)
		if fl.OnSelect != nil && id < len(fl.Items) {
			fl.OnSelect(fl.Items[id])
		}
		fl.updateToolbarState()
	}
	fl.EmptyState = newFileListEmptyState()
	fl.updateEmptyState()
	return fl
}

func newFileListEmptyState() *fyne.Container {
	title := widget.NewLabel("拖入 PDF，开始合并")
	title.TextStyle = fyne.TextStyle{Bold: true}
	title.Alignment = fyne.TextAlignCenter

	hint := widget.NewLabel("也可以点击上方按钮添加文件或文件夹")
	hint.Alignment = fyne.TextAlignCenter

	return container.NewCenter(container.NewVBox(
		widget.NewIcon(theme.UploadIcon()),
		title,
		hint,
	))
}

func (fl *FileList) AddFiles(paths []string) {
	for _, p := range paths {
		// Skip duplicates
		if fl.hasPath(p) {
			continue
		}
		info, err := os.Stat(p)
		if err != nil {
			continue
		}
		pageCount, err := pdf.GetPageCount(p)
		if err != nil {
			pageCount = 0
		}
		fl.Items = append(fl.Items, &FileItem{
			Path:      p,
			Name:      filepath.Base(p),
			Size:      info.Size(),
			PageCount: pageCount,
		})
	}
	fl.List.Refresh()
	if len(fl.Items) > 0 && fl.selectedID == -1 {
		fl.selectedID = 0
		fl.List.Select(0)
	}
	fl.updateEmptyState()
	fl.updateToolbarState()
	if fl.onChange != nil {
		fl.onChange()
	}
}

func (fl *FileList) hasPath(path string) bool {
	for _, item := range fl.Items {
		if item.Path == path {
			return true
		}
	}
	return false
}

func (fl *FileList) RemoveSelected() {
	if fl.selectedID >= 0 && fl.selectedID < len(fl.Items) {
		fl.Items = append(fl.Items[:fl.selectedID], fl.Items[fl.selectedID+1:]...)
		fl.List.Refresh()
		if len(fl.Items) == 0 {
			fl.selectedID = -1
		} else if fl.selectedID >= len(fl.Items) {
			fl.selectedID = len(fl.Items) - 1
			fl.List.Select(widget.ListItemID(fl.selectedID))
		} else {
			fl.List.Select(widget.ListItemID(fl.selectedID))
		}
		fl.updateEmptyState()
		fl.updateToolbarState()
		if fl.onChange != nil {
			fl.onChange()
		}
	}
}

func (fl *FileList) MoveUp() {
	if fl.selectedID > 0 {
		fl.Items[fl.selectedID], fl.Items[fl.selectedID-1] = fl.Items[fl.selectedID-1], fl.Items[fl.selectedID]
		fl.selectedID--
		fl.List.Refresh()
		fl.List.Select(widget.ListItemID(fl.selectedID))
		fl.updateToolbarState()
		if fl.onChange != nil {
			fl.onChange()
		}
	}
}

func (fl *FileList) MoveDown() {
	if fl.selectedID >= 0 && fl.selectedID < len(fl.Items)-1 {
		fl.Items[fl.selectedID], fl.Items[fl.selectedID+1] = fl.Items[fl.selectedID+1], fl.Items[fl.selectedID]
		fl.selectedID++
		fl.List.Refresh()
		fl.List.Select(widget.ListItemID(fl.selectedID))
		fl.updateToolbarState()
		if fl.onChange != nil {
			fl.onChange()
		}
	}
}

func (fl *FileList) Clear() {
	fl.Items = nil
	fl.selectedID = -1
	fl.List.Refresh()
	fl.updateEmptyState()
	fl.updateToolbarState()
	if fl.onChange != nil {
		fl.onChange()
	}
}

func (fl *FileList) GetPaths() []string {
	var paths []string
	for _, item := range fl.Items {
		paths = append(paths, item.Path)
	}
	return paths
}

func (fl *FileList) SelectedItem() *FileItem {
	if fl.selectedID < 0 || fl.selectedID >= len(fl.Items) {
		return nil
	}
	return fl.Items[fl.selectedID]
}

func (fl *FileList) findPDFs(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var paths []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if utils.IsPDF(e.Name()) {
			paths = append(paths, filepath.Join(dir, e.Name()))
		}
	}
	return paths
}

func (fl *FileList) CreateToolbar() fyne.CanvasObject {
	addBtn := widget.NewButtonWithIcon("添加", theme.ContentAddIcon(), func() {
		dialog.ShowFileOpen(func(reader fyne.URIReadCloser, err error) {
			if err != nil || reader == nil {
				return
			}
			defer reader.Close()
			path := reader.URI().Path()
			if utils.IsPDF(path) {
				fl.AddFiles([]string{path})
			}
		}, fl.Window)
	})
	addBtn.Importance = widget.HighImportance

	folderBtn := widget.NewButtonWithIcon("文件夹", theme.FolderOpenIcon(), func() {
		dialog.ShowFolderOpen(func(uri fyne.ListableURI, err error) {
			if err != nil || uri == nil {
				return
			}
			paths := fl.findPDFs(uri.Path())
			if len(paths) > 0 {
				fl.AddFiles(paths)
			}
		}, fl.Window)
	})

	fl.removeBtn = widget.NewButtonWithIcon("移除", theme.DeleteIcon(), fl.RemoveSelected)
	fl.upBtn = widget.NewButtonWithIcon("上移", theme.MoveUpIcon(), fl.MoveUp)
	fl.downBtn = widget.NewButtonWithIcon("下移", theme.MoveDownIcon(), fl.MoveDown)
	fl.sortBtn = widget.NewButtonWithIcon("排序", theme.ViewRefreshIcon(), fl.SortByName)
	fl.clearBtn = widget.NewButtonWithIcon("清空", theme.ContentClearIcon(), fl.Clear)
	fl.updateToolbarState()

	return container.NewVBox(
		container.NewHBox(addBtn, folderBtn, layout.NewSpacer()),
		container.NewHBox(fl.removeBtn, layout.NewSpacer(), fl.upBtn, fl.downBtn, fl.sortBtn, fl.clearBtn),
	)
}

func (fl *FileList) SortByName() {
	sort.Slice(fl.Items, func(i, j int) bool {
		return fl.Items[i].Name < fl.Items[j].Name
	})
	fl.List.Refresh()
	if fl.onChange != nil {
		fl.onChange()
	}
}

func (fl *FileList) updateEmptyState() {
	if fl.EmptyState == nil {
		return
	}
	if len(fl.Items) == 0 {
		fl.EmptyState.Show()
		return
	}
	fl.EmptyState.Hide()
}

func (fl *FileList) updateToolbarState() {
	hasItems := len(fl.Items) > 0
	hasSelection := fl.selectedID >= 0 && fl.selectedID < len(fl.Items)

	setEnabled(fl.removeBtn, hasSelection)
	setEnabled(fl.upBtn, hasSelection && fl.selectedID > 0)
	setEnabled(fl.downBtn, hasSelection && fl.selectedID < len(fl.Items)-1)
	setEnabled(fl.sortBtn, len(fl.Items) > 1)
	setEnabled(fl.clearBtn, hasItems)
}

func setEnabled(btn *widget.Button, enabled bool) {
	if btn == nil {
		return
	}
	if enabled {
		btn.Enable()
		return
	}
	btn.Disable()
}
