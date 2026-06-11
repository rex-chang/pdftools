package ui

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/layout"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"
)

type Settings struct {
	Container   *fyne.Container
	OutputName  *widget.Entry
	OutputDir   *widget.Entry
	OnMerge     func(string)
	MergeBtn    *widget.Button
	Progress    *widget.ProgressBarInfinite
	ProgressBar *widget.ProgressBar
	StatusLabel *widget.Label
	Window      fyne.Window
}

func NewSettings(w fyne.Window, onMerge func(string)) *Settings {
	s := &Settings{
		Window:  w,
		OnMerge: onMerge,
	}

	title := widget.NewLabel("输出设置")
	title.TextStyle = fyne.TextStyle{Bold: true}

	s.OutputName = widget.NewEntry()
	s.OutputName.SetText(fmt.Sprintf("合并_%s.pdf", time.Now().Format("20060102_150405")))
	s.OutputName.OnChanged = func(text string) {
	}

	homeDir, _ := os.UserHomeDir()
	s.OutputDir = widget.NewEntry()
	s.OutputDir.SetText(homeDir)
	s.OutputDir.OnChanged = func(text string) {
	}

	dirBtn := widget.NewButtonWithIcon("浏览", theme.FolderOpenIcon(), func() {
		dialog.ShowFolderOpen(func(uri fyne.ListableURI, err error) {
			if err != nil || uri == nil {
				return
			}
			s.OutputDir.SetText(uri.Path())
		}, w)
	})

	s.MergeBtn = widget.NewButtonWithIcon("合并 PDF", theme.DocumentSaveIcon(), func() {
		if s.OnMerge != nil {
			s.OnMerge(s.getOutputPath())
		}
	})
	s.MergeBtn.Importance = widget.HighImportance
	s.MergeBtn.Disable()

	s.ProgressBar = widget.NewProgressBar()
	s.ProgressBar.Hide()

	s.Progress = widget.NewProgressBarInfinite()
	s.Progress.Hide()

	s.StatusLabel = widget.NewLabel("")
	s.StatusLabel.Wrapping = fyne.TextWrapOff
	s.StatusLabel.SetText("等待添加至少 2 个 PDF 文件")

	dirLabel := widget.NewLabel("目录:")
	dirRow := container.NewBorder(nil, nil, dirLabel, dirBtn, s.OutputDir)

	nameLabel := widget.NewLabel("文件名:")
	nameRow := container.NewBorder(nil, nil, nameLabel, nil, s.OutputName)

	formBox := container.NewVBox(dirRow, nameRow)
	actionRow := container.NewHBox(layout.NewSpacer(), s.MergeBtn)
	progressBox := container.NewBorder(nil, nil, nil, nil, container.NewHBox(s.ProgressBar, s.Progress))

	s.Container = container.NewVBox(
		widget.NewSeparator(),
		container.NewPadded(container.NewVBox(
			title,
			formBox,
			s.StatusLabel,
			actionRow,
		)),
		progressBox,
	)

	return s
}

func (s *Settings) SetMergeEnabled(enabled bool) {
	if enabled {
		s.MergeBtn.Enable()
	} else {
		s.MergeBtn.Disable()
	}
}

func (s *Settings) getOutputPath() string {
	return filepath.Join(s.OutputDir.Text, s.OutputName.Text)
}

func (s *Settings) SetProgress(value float64) {
	s.ProgressBar.SetValue(value)
}

func (s *Settings) ShowProgress(show bool) {
	if show {
		s.ProgressBar.Show()
	} else {
		s.ProgressBar.Hide()
	}
}

func (s *Settings) ShowIndeterminate(show bool) {
	if show {
		s.Progress.Start()
		s.Progress.Show()
	} else {
		s.Progress.Stop()
		s.Progress.Hide()
	}
}

func (s *Settings) SetStatus(text string) {
	s.StatusLabel.SetText(text)
	s.StatusLabel.Show()
}
