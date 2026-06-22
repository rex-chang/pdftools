package pdf

import (
	"fmt"
	"io"
	"math"
	"regexp"
	"sort"
	"strings"

	"github.com/ledongthuc/pdf"
)

type InvoiceData struct {
	FileName     string
	Type         string
	TotalWithTax string
	TotalBefore  string
	TaxAmount    string
}

func (inv *InvoiceData) IsEmpty() bool {
	return inv.TotalWithTax == "" && inv.TotalBefore == "" && inv.TaxAmount == ""
}

func CSVHeader() []string {
	return []string{"文件名", "类型", "价税合计", "金额(不含税)", "税额"}
}

func (inv *InvoiceData) ToCSVRow() []string {
	return []string{inv.FileName, inv.Type, inv.TotalWithTax, inv.TotalBefore, inv.TaxAmount}
}

func ExtractInvoiceData(path string) (*InvoiceData, error) {
	f, r, err := pdf.Open(path)
	if err != nil {
		return nil, fmt.Errorf("cannot open %s: %w", path, err)
	}
	defer f.Close()

	texts, err := r.GetStyledTexts()
	if err != nil {
		return nil, fmt.Errorf("text extraction failed: %w", err)
	}

	return parse(path, texts), nil
}

func ExtractInvoiceDataFromFiles(paths []string) []*InvoiceData {
	var results []*InvoiceData
	for _, p := range paths {
		inv, err := ExtractInvoiceData(p)
		if err != nil {
			results = append(results, &InvoiceData{
				FileName:     p,
				TotalWithTax: fmt.Sprintf("失败: %v", err),
			})
			continue
		}
		results = append(results, inv)
	}
	return results
}

type block struct{ X, Y float64; S string }
type yline  struct{ y float64; blocks []block }

func parse(path string, texts []pdf.Text) *InvoiceData {
	inv := &InvoiceData{FileName: path}

	// Build blocks sorted Y desc, X asc
	bs := make([]block, len(texts))
	for i, t := range texts {
		bs[i] = block{t.X, t.Y, t.S}
	}
	sort.Slice(bs, func(i, j int) bool {
		if math.Abs(bs[i].Y-bs[j].Y) > 2.0 { return bs[i].Y > bs[j].Y }
		return bs[i].X < bs[j].X
	})

	var lines []yline
	var cur yline
	for _, b := range bs {
		if len(cur.blocks) == 0 || math.Abs(b.Y-cur.y) <= 2.0 {
			if len(cur.blocks) == 0 { cur.y = b.Y }
			cur.blocks = append(cur.blocks, b)
		} else {
			lines = append(lines, cur)
			cur = yline{y: b.Y, blocks: []block{b}}
		}
	}
	if len(cur.blocks) > 0 { lines = append(lines, cur) }

	// Find the full concatenated text for type extraction
	var allText string
	for _, line := range lines {
		allText += concat(line.blocks) + "\n"
	}
	inv.Type = findType(allText)

	// Find 合计 and 价税合计 lines
	typeNum := regexp.MustCompile(`(\d+\.\d+)`)
	
	for _, line := range lines {
		text := concat(line.blocks)
		compact := strings.ReplaceAll(text, " ", "")

		// "合计" line (NOT "价税合计") — has 金额 and 税额 in columns
		if strings.Contains(compact, "合计") && !strings.Contains(compact, "价税合计") {
			nums := extractLineAmounts(line.blocks, typeNum)
			if len(nums) >= 1 { inv.TotalBefore = nums[0] }
			if len(nums) >= 2 { inv.TaxAmount  = nums[1] }
		}

		// "价税合计" line — has the total
		if strings.Contains(text, "价税合计") || strings.Contains(compact, "价税合计") {
			nums := extractLineAmounts(line.blocks, typeNum)
			if len(nums) >= 1 {
				inv.TotalWithTax = nums[0]
			}
		}
	}

	// Fallback: if 价税合计 not found with keyword, use last amount
	if inv.TotalWithTax == "" {
		allAmounts := typeNum.FindAllString(allText, -1)
		for i := len(allAmounts) - 1; i >= 0; i-- {
			if allAmounts[i] != inv.TotalBefore && allAmounts[i] != inv.TaxAmount {
				inv.TotalWithTax = allAmounts[i]
				break
			}
		}
	}

	return inv
}

// extractLineAmounts returns all ¥-prefixed decimal amounts on a line, in X order.
func extractLineAmounts(blocks []block, numRe *regexp.Regexp) []string {
	sorted := make([]block, len(blocks))
	copy(sorted, blocks)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].X < sorted[j].X })

	// First try: extract all ¥amount patterns from the full text of the line
	fullText := concat(sorted)
	// Match ¥123.45 or ¥1,234.56 or ¥0.00
	yenRe := regexp.MustCompile(`¥\s*([\d,]+(?:\.\d+)?)`)
	if m := yenRe.FindAllStringSubmatch(fullText, -1); len(m) >= 1 {
		var results []string
		for _, pair := range m {
			if len(pair) > 1 {
				val := strings.ReplaceAll(pair[1], ",", "")
				results = append(results, val)
			}
		}
		return results
	}

	// Fallback: ¥ and number in separate blocks
	var results []string
	seenYen := false
	for _, b := range sorted {
		s := strings.TrimSpace(b.S)
		if s == "¥" {
			seenYen = true
			continue
		}
		if seenYen {
			if m := numRe.FindString(s); m != "" {
				results = append(results, m)
			}
			seenYen = false
		}
	}
	if len(results) == 0 {
		for _, b := range sorted {
			if m := numRe.FindString(strings.TrimSpace(b.S)); m != "" {
				results = append(results, m)
			}
		}
	}
	return results
}

func findType(text string) string {
	re := regexp.MustCompile(`\*[^*]+\*`)
	if m := re.FindString(text); m != "" {
		return strings.Trim(m, "*")
	}
	return ""
}

func concat(blocks []block) string {
	var s string
	for _, b := range blocks { s += b.S }
	return s
}

// --- Debug ---

func DebugText(path string) (string, error) {
	f, r, err := pdf.Open(path)
	if err != nil { return "", err }
	defer f.Close()
	reader, err := r.GetPlainText()
	if err != nil { return "", err }
	b, err := io.ReadAll(reader)
	if err != nil { return "", err }
	return string(b), nil
}
