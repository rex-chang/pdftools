package ui

import (
	"fmt"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"

	"pdfmerge/utils"
)

type Preview struct {
	Container *fyne.Container
	title     *widget.Label
	fileName  *widget.Label
	fileInfo  *widget.Label
	filePath  *widget.Label
	pathTitle *widget.Label
	emptyMsg  *widget.Label
	emptyHint *widget.Label
	detailBox *fyne.Container
	emptyBox  *fyne.Container
}

func NewPreview() *Preview {
	p := &Preview{}
	p.title = widget.NewLabel("预览")
	p.title.TextStyle = fyne.TextStyle{Bold: true}

	p.fileName = widget.NewLabel("")
	p.fileName.TextStyle = fyne.TextStyle{Bold: true}
	p.fileName.Wrapping = fyne.TextWrapWord

	p.fileInfo = widget.NewLabel("")

	p.pathTitle = widget.NewLabel("文件路径")
	p.pathTitle.TextStyle = fyne.TextStyle{Bold: true}
	p.filePath = widget.NewLabel("")
	p.filePath.Wrapping = fyne.TextWrapWord
	p.filePath.Hide()

	p.emptyMsg = widget.NewLabel("选择 PDF 文件以查看详情")
	p.emptyMsg.Alignment = fyne.TextAlignCenter
	p.emptyMsg.TextStyle = fyne.TextStyle{Bold: true}

	p.emptyHint = widget.NewLabel("左侧队列顺序就是最终合并顺序")
	p.emptyHint.Alignment = fyne.TextAlignCenter

	fileIcon := widget.NewIcon(theme.FileTextIcon())
	p.detailBox = container.NewVBox(
		container.NewCenter(fileIcon),
		p.fileName,
		p.fileInfo,
		widget.NewSeparator(),
		p.pathTitle,
		p.filePath,
	)

	p.emptyBox = container.NewCenter(container.NewVBox(
		widget.NewIcon(theme.VisibilityIcon()),
		p.emptyMsg,
		p.emptyHint,
	))

	p.Container = container.NewBorder(
		container.NewVBox(p.title, widget.NewSeparator()),
		nil,
		nil,
		nil,
		container.NewPadded(container.NewStack(p.detailBox, p.emptyBox)),
	)
	p.pathTitle.Hide()

	p.ShowPlaceholder()
	return p
}

func (p *Preview) ShowFile(item *FileItem) {
	if item == nil {
		p.ShowPlaceholder()
		return
	}
	p.fileName.SetText(item.Name)
	p.fileInfo.SetText(fmt.Sprintf("%s  ·  %d 页", utils.FormatSize(item.Size), item.PageCount))
	p.fileName.Show()
	p.fileInfo.Show()
	p.pathTitle.Show()
	p.filePath.SetText(item.Path)
	p.filePath.Show()
	p.detailBox.Show()
	p.emptyMsg.Hide()
	p.emptyHint.Hide()
	p.emptyBox.Hide()
}

func (p *Preview) ShowPlaceholder() {
	p.fileName.Hide()
	p.fileInfo.Hide()
	p.pathTitle.Hide()
	p.filePath.Hide()
	p.detailBox.Hide()
	p.emptyMsg.Show()
	p.emptyHint.Show()
	p.emptyBox.Show()
}
