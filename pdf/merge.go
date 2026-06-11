package pdf

import (
	"github.com/pdfcpu/pdfcpu/pkg/api"
)

func MergePDFs(inputPaths []string, outputPath string) error {
	return api.MergeCreateFile(inputPaths, outputPath, false, nil)
}
