package pdf

import (
	"github.com/pdfcpu/pdfcpu/pkg/api"
)

func GetPageCount(path string) (int, error) {
	return api.PageCountFile(path)
}
