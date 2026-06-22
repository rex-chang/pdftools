package ui

import (
	"encoding/csv"
	"fmt"
	"path/filepath"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/layout"
	"fyne.io/fyne/v2/storage"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"

	"pdfmerge/pdf"
)

// ShowInvoiceDialog opens a dialog listing invoice price/tax data from all PDFs
// and allows CSV export.
func ShowInvoiceDialog(w fyne.Window, files []*pdf.InvoiceData, debugTexts []string) {
	if len(files) == 0 {
		dialog.ShowInformation("提示", "没有可提取的发票数据", w)
		return
	}

	title := widget.NewLabelWithStyle("发票价税信息", fyne.TextAlignLeading, fyne.TextStyle{Bold: true})

	// Build table header
	header := container.NewGridWithColumns(5,
		makeHeaderLabel("文件名"),
		makeHeaderLabel("类型"),
		makeHeaderLabel("价税合计"),
		makeHeaderLabel("金额(不含税)"),
		makeHeaderLabel("税额"),
	)
	headerSep := widget.NewSeparator()

	// Build table rows
	var rows []fyne.CanvasObject
	for _, f := range files {
		row := container.NewGridWithColumns(5,
			makeCellLabel(filepath.Base(f.FileName)),
			makeCellLabel(f.Type),
			makeCellLabel(f.TotalWithTax),
			makeCellLabel(f.TotalBefore),
			makeCellLabel(f.TaxAmount),
		)
		rows = append(rows, row)
	}

	// Scrollable content
	allContent := append([]fyne.CanvasObject{header, headerSep}, rows...)
	contentVBox := container.NewVBox(allContent...)
	scroll := container.NewScroll(contentVBox)
	scroll.SetMinSize(fyne.NewSize(700, 350))

	// Buttons
	exportBtn := widget.NewButtonWithIcon("导出 CSV", theme.DownloadIcon(), func() {
		saveDialog := dialog.NewFileSave(func(writer fyne.URIWriteCloser, err error) {
			if err != nil || writer == nil {
				return
			}
			defer writer.Close()
			if saveErr := exportInvoicesToCSV(writer, files); saveErr != nil {
				dialog.ShowError(fmt.Errorf("导出失败: %v", saveErr), w)
			}
		}, w)
		saveDialog.SetFileName("发票数据.csv")
		saveDialog.SetFilter(storage.NewExtensionFileFilter([]string{".csv"}))
		saveDialog.Show()
	})

	closeBtn := widget.NewButton("关闭", nil)
	btnBox := container.NewHBox(layout.NewSpacer(), exportBtn, closeBtn)

	// Debug button: always show to inspect raw text
	var debugBtn *widget.Button
	if len(debugTexts) > 0 {
		debugBtn = widget.NewButton("原始文本", func() {
			showDebugText(w, debugTexts)
		})
	}
	if debugBtn != nil {
		btnBox = container.NewHBox(layout.NewSpacer(), debugBtn, exportBtn, closeBtn)
	} else {
		btnBox = container.NewHBox(layout.NewSpacer(), exportBtn, closeBtn)
	}

	// Wrap with title and buttons using Border layout
	outer := container.NewBorder(
		container.NewVBox(
			title,
			widget.NewSeparator(),
		),
		container.NewVBox(
			widget.NewSeparator(),
			btnBox,
		),
		nil, nil,
		scroll,
	)

	d := dialog.NewCustomWithoutButtons("提取结果", outer, w)
	d.Resize(fyne.NewSize(750, 500))
	closeBtn.OnTapped = d.Hide
	d.Show()
}

func showDebugText(w fyne.Window, texts []string) {
	var items []fyne.CanvasObject
	for i, t := range texts {
		items = append(items, widget.NewLabelWithStyle(
			fmt.Sprintf("━━━ 文件 %d ━━━", i+1),
			fyne.TextAlignLeading,
			fyne.TextStyle{Bold: true},
		))
		entry := widget.NewMultiLineEntry()
		entry.SetText(t)
		entry.Wrapping = fyne.TextWrapBreak
		entry.SetMinRowsVisible(8)
		items = append(items, entry)
	}

	scroll := container.NewScroll(container.NewVBox(items...))
	scroll.SetMinSize(fyne.NewSize(700, 400))

	d := dialog.NewCustomWithoutButtons("原始提取文本(调试)", scroll, w)
	d.Resize(fyne.NewSize(750, 550))

	closeBtn := widget.NewButton("关闭", d.Hide)
	outer := container.NewBorder(nil, container.NewCenter(closeBtn), nil, nil, scroll)
	d = dialog.NewCustomWithoutButtons("原始提取文本(调试)", outer, w)
	d.Resize(fyne.NewSize(750, 550))
	d.Show()
}

func makeHeaderLabel(text string) *widget.Label {
	l := widget.NewLabel(text)
	l.TextStyle = fyne.TextStyle{Bold: true}
	return l
}

func makeCellLabel(text string) *widget.Label {
	l := widget.NewLabel(text)
	l.Truncation = fyne.TextTruncateEllipsis
	return l
}

// exportInvoicesToCSV writes invoice data to CSV via the writer.
func exportInvoicesToCSV(writer fyne.URIWriteCloser, data []*pdf.InvoiceData) error {
	csvWriter := csv.NewWriter(writer)
	defer csvWriter.Flush()

	if err := csvWriter.Write(pdf.CSVHeader()); err != nil {
		return err
	}

	for _, inv := range data {
		if err := csvWriter.Write(inv.ToCSVRow()); err != nil {
			return err
		}
	}

	return csvWriter.Error()
}
