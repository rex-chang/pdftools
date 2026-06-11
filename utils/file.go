package utils

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func IsPDF(path string) bool {
	return strings.ToLower(filepath.Ext(path)) == ".pdf"
}

func FileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func GetFileName(path string) string {
	return filepath.Base(path)
}

func GetExtension(path string) string {
	return filepath.Ext(path)
}

func ChangeExtension(path, newExt string) string {
	return strings.TrimSuffix(path, filepath.Ext(path)) + newExt
}

const (
	KB = 1024
	MB = 1024 * KB
	GB = 1024 * MB
)

func FormatSize(bytes int64) string {
	switch {
	case bytes >= GB:
		return fmt.Sprintf("%.1f GB", float64(bytes)/float64(GB))
	case bytes >= MB:
		return fmt.Sprintf("%.1f MB", float64(bytes)/float64(MB))
	case bytes >= KB:
		return fmt.Sprintf("%.1f KB", float64(bytes)/float64(KB))
	default:
		return fmt.Sprintf("%d B", bytes)
	}
}
