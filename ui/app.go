package ui

import (
	"context"
	"fmt"
	"path/filepath"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/widget"

	"pdfmerge/pdf"
	"pdfmerge/utils"
)

type App struct {
	fyneApp  fyne.App
	Window   fyne.Window
	FileList *FileList
	Preview  *Preview
	Settings *Settings
	cancel   context.CancelFunc
}

func NewApp() *App {
	a := &App{}
	a.fyneApp = app.NewWithID("com.pdfmerge.app")
	a.Window = a.fyneApp.NewWindow("PDF 合并")
	a.Window.Resize(fyne.NewSize(1080, 680))
	a.Window.CenterOnScreen()

	a.Preview = NewPreview()

	a.FileList = NewFileList(a.Window, func() {
		a.updatePreview()
		a.updateMergeState()
	})

	a.FileList.OnSelect = func(item *FileItem) {
		a.Preview.ShowFile(item)
	}

	a.Settings = NewSettings(a.Window, a.handleMerge)
	a.Settings.OnExtract = a.handleExtract

	toolbar := a.FileList.CreateToolbar()
	listTitle := widget.NewLabel("文件队列")
	listTitle.TextStyle = fyne.TextStyle{Bold: true}
	listHint := widget.NewLabel("按列表顺序合并")
	listHint.Alignment = fyne.TextAlignTrailing
	listHeader := container.NewBorder(nil, nil, listTitle, listHint)
	listArea := container.NewStack(a.FileList.List, a.FileList.EmptyState)

	leftPanel := container.NewBorder(
		container.NewVBox(
			listHeader,
			widget.NewSeparator(),
			toolbar,
			widget.NewSeparator(),
		),
		nil,
		nil,
		nil,
		listArea,
	)

	rightPanel := a.Preview.Container

	split := container.NewHSplit(leftPanel, rightPanel)
	split.SetOffset(0.42)

	mainLayout := container.NewBorder(
		nil,
		a.Settings.Container,
		nil,
		nil,
		split,
	)

	a.Window.SetContent(mainLayout)

	a.Window.SetOnDropped(func(pos fyne.Position, uris []fyne.URI) {
		var paths []string
		for _, uri := range uris {
			if utils.IsPDF(uri.Path()) {
				paths = append(paths, uri.Path())
			}
		}
		if len(paths) > 0 {
			a.FileList.AddFiles(paths)
		}
	})

	return a
}

func (a *App) Run() {
	a.Window.ShowAndRun()
}

func (a *App) updatePreview() {
	if item := a.FileList.SelectedItem(); item != nil {
		a.Preview.ShowFile(item)
		return
	}
	a.Preview.ShowPlaceholder()
}

func (a *App) updateMergeState() {
	count := len(a.FileList.Items)
	a.Settings.SetMergeEnabled(count >= 2)
	a.Settings.SetInvEnabled(count > 0)
}

func (a *App) handleExtract() {
	paths := a.FileList.GetPaths()
	if len(paths) == 0 {
		return
	}

	go func() {
		results := pdf.ExtractInvoiceDataFromFiles(paths)

		// Collect raw text for debugging
		var debugTexts []string
		for _, p := range paths {
			text, err := pdf.DebugText(p)
			if err == nil {
				debugTexts = append(debugTexts, text)
			}
		}

		ShowInvoiceDialog(a.Window, results, debugTexts)
	}()
}

func (a *App) handleMerge(outputPath string) {
	paths := a.FileList.GetPaths()
	if len(paths) < 2 {
		dialog.ShowError(fmt.Errorf("请至少添加 2 个 PDF 文件"), a.Window)
		return
	}

	if outputPath == "" {
		dialog.ShowError(fmt.Errorf("输出路径为空"), a.Window)
		return
	}

	// Cancel any previous merge
	if a.cancel != nil {
		a.cancel()
	}

	ctx, cancel := context.WithCancel(context.Background())
	a.cancel = cancel

	a.Settings.SetStatus("合并中...")
	a.Settings.ShowIndeterminate(true)
	a.Settings.ShowProgress(false)
	a.Settings.MergeBtn.Disable()

	go func() {
		defer cancel()

		err := pdf.MergePDFs(paths, outputPath)
		if err != nil {
			// Check if cancelled
			if ctx.Err() != nil {
				a.Settings.SetStatus("已取消")
			} else {
				a.Settings.SetStatus(fmt.Sprintf("错误: %v", err))
			}
			a.Settings.ShowIndeterminate(false)
			a.Settings.ShowProgress(false)
			a.Settings.SetMergeEnabled(len(a.FileList.Items) >= 2)
			return
		}

		a.Settings.ShowIndeterminate(false)
		a.Settings.SetProgress(1.0)
		a.Settings.ShowProgress(true)
		a.Settings.SetStatus(fmt.Sprintf("已合并 %d 个文件 → %s", len(paths), filepath.Base(outputPath)))
		a.Settings.SetMergeEnabled(len(a.FileList.Items) >= 2)

		dialog.ShowInformation("完成",
			fmt.Sprintf("成功合并 %d 个 PDF 文件到:\n%s", len(paths), outputPath),
			a.Window)
	}()
}
