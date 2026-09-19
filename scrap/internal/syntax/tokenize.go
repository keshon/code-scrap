package syntax

import (
	"bytes"
	"strings"
)

// Token classes. The viewer and the raster renderer share this palette index.
const (
	ClsText uint8 = iota
	ClsKeyword
	ClsString
	ClsComment
	ClsNumber
	ClsType
	ClsPunct
	ClsPreproc
	ClsFunc
	NumClasses
)

// Seg is a run of same-class, non-space characters on one line.
type Seg struct {
	Col, Len uint16
	Cls      uint8
}

// Brace is an unquoted, uncommented '{' or '}' — input for the scope finder.
type Brace struct {
	Line int32
	Col  int32
	Open bool
}

// Scan collects structural facts while tokenizing, for the scope finder.
type Scan struct {
	Braces   []Brace
	Branches []int32 // prefix sums: Branches[i] = branch points in lines [0, i)
}

// BranchesIn counts branch points (if/for/while/case/catch/&&/||/?) in the
// inclusive line range.
func (s *Scan) BranchesIn(start, end int32) int32 {
	if s == nil || int(end)+1 >= len(s.Branches) {
		return 0
	}
	return s.Branches[end+1] - s.Branches[start]
}

var branchWords = map[string]bool{
	"if": true, "for": true, "while": true, "case": true, "catch": true, "elif": true, "except": true,
	"foreach": true, "when": true, "guard": true,
}

const tabWidth = 4

func isIdentStart(c byte) bool {
	return c == '_' || c == '$' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80
}
func isIdent(c byte) bool { return isIdentStart(c) || (c >= '0' && c <= '9') }
func isDigit(c byte) bool { return c >= '0' && c <= '9' }

// SplitLines splits on '\n', dropping a trailing '\r' and expanding tabs.
func SplitLines(src []byte) []string {
	if len(src) == 0 {
		return nil
	}
	n := bytes.Count(src, []byte{'\n'}) + 1
	out := make([]string, 0, n)
	var buf []byte
	for len(src) > 0 {
		i := bytes.IndexByte(src, '\n')
		var line []byte
		if i < 0 {
			line, src = src, nil
		} else {
			line, src = src[:i], src[i+1:]
		}
		if len(line) > 0 && line[len(line)-1] == '\r' {
			line = line[:len(line)-1]
		}
		if bytes.IndexByte(line, '\t') >= 0 {
			buf = buf[:0]
			for _, c := range line {
				if c == '\t' {
					for k := tabWidth - len(buf)%tabWidth; k > 0; k-- {
						buf = append(buf, ' ')
					}
				} else {
					buf = append(buf, c)
				}
			}
			out = append(out, string(buf))
		} else {
			out = append(out, string(line))
		}
	}
	return out
}

// Tokenize classifies every line. If scan is non-nil it also records brace
// events and branch counts for the scope finder.
func Tokenize(lines []string, l *Lang, wantSegs bool, scan *Scan) [][]Seg {
	var segs [][]Seg
	if wantSegs {
		segs = make([][]Seg, len(lines))
	}
	var branches int32
	if scan != nil {
		scan.Branches = make([]int32, len(lines)+1)
	}
	inBlock := false
	var inDelim string // open raw/triple string delimiter
	for li, line := range lines {
		if scan != nil {
			scan.Branches[li] = branches
		}
		var out []Seg
		emit := func(col, n int, cls uint8) {
			if !wantSegs || n <= 0 {
				return
			}
			// split on spaces so dashes keep word gaps
			start := -1
			for k := col; k <= col+n; k++ {
				sp := k == col+n || line[k] == ' '
				if !sp && start < 0 {
					start = k
				} else if sp && start >= 0 {
					if len(out) > 0 {
						p := &out[len(out)-1]
						if p.Cls == cls && int(p.Col+p.Len) == start {
							p.Len += uint16(k - start)
							start = -1
							continue
						}
					}
					if start < 0xFFFF {
						ln := k - start
						if start+ln > 0xFFFF {
							ln = 0xFFFF - start
						}
						out = append(out, Seg{uint16(start), uint16(ln), cls})
					}
					start = -1
				}
			}
		}
		i := 0
		n := len(line)
		firstNonSpace := true
		for i < n {
			if inBlock {
				j := indexFrom(line, l.BlockClose, i)
				if j < 0 {
					emit(i, n-i, ClsComment)
					i = n
					break
				}
				emit(i, j+len(l.BlockClose)-i, ClsComment)
				i = j + len(l.BlockClose)
				inBlock = false
				continue
			}
			if inDelim != "" {
				j := indexFrom(line, inDelim, i)
				if j < 0 {
					emit(i, n-i, ClsString)
					i = n
					break
				}
				emit(i, j+len(inDelim)-i, ClsString)
				i = j + len(inDelim)
				inDelim = ""
				continue
			}
			c := line[i]
			if c == ' ' {
				i++
				continue
			}
			wasFirst := firstNonSpace
			firstNonSpace = false
			// comments
			if l.BlockOpen != "" && hasAt(line, l.BlockOpen, i) {
				inBlock = true
				emit(i, len(l.BlockOpen), ClsComment)
				i += len(l.BlockOpen)
				continue
			}
			lc := false
			for _, p := range l.LineComments {
				if hasAt(line, p, i) {
					lc = true
					break
				}
			}
			if lc && !(l.Preproc && c == '#') {
				emit(i, n-i, ClsComment)
				i = n
				break
			}
			if l.Preproc && c == '#' && wasFirst {
				j := i + 1
				for j < n && line[j] == ' ' {
					j++
				}
				for j < n && isIdent(line[j]) {
					j++
				}
				emit(i, j-i, ClsPreproc)
				i = j
				continue
			}
			// strings
			if l.TripleQuote && (hasAt(line, `"""`, i) || hasAt(line, `'''`, i)) {
				d := line[i : i+3]
				j := indexFrom(line, d, i+3)
				if j < 0 {
					inDelim = d
					emit(i, n-i, ClsString)
					i = n
					break
				}
				emit(i, j+3-i, ClsString)
				i = j + 3
				continue
			}
			if l.RawQuote != 0 && c == l.RawQuote {
				j := indexFrom(line, string(c), i+1)
				if j < 0 {
					inDelim = string(c)
					emit(i, n-i, ClsString)
					i = n
					break
				}
				emit(i, j+1-i, ClsString)
				i = j + 1
				continue
			}
			if l.Quotes != "" && strings.IndexByte(l.Quotes, c) >= 0 {
				j := i + 1
				for j < n && line[j] != c {
					if line[j] == '\\' {
						j++
					}
					j++
				}
				if j > n {
					j = n
				}
				end := j + 1
				if end > n {
					end = n
				}
				emit(i, end-i, ClsString)
				i = end
				continue
			}
			if isDigit(c) {
				j := i + 1
				for j < n && (isIdent(line[j]) || line[j] == '.') {
					j++
				}
				emit(i, j-i, ClsNumber)
				i = j
				continue
			}
			if isIdentStart(c) {
				j := i + 1
				for j < n && isIdent(line[j]) {
					j++
				}
				w := line[i:j]
				if scan != nil && branchWords[w] {
					branches++
				}
				cls := ClsText
				switch {
				case l.Keywords[w]:
					cls = ClsKeyword
				case j < n && line[j] == '(':
					cls = ClsFunc
				case len(w) > 1 && w[0] >= 'A' && w[0] <= 'Z':
					cls = ClsType
				}
				emit(i, j-i, cls)
				i = j
				continue
			}
			if scan != nil {
				switch {
				case c == '{' || c == '}':
					scan.Braces = append(scan.Braces, Brace{Line: int32(li), Col: int32(i), Open: c == '{'})
				case (c == '&' || c == '|') && i+1 < n && line[i+1] == c:
					branches++
				case c == '?' && i+1 < n && line[i+1] == ' ':
					branches++
				}
			}
			emit(i, 1, ClsPunct)
			i++
		}
		if wantSegs {
			segs[li] = out
		}
	}
	if scan != nil {
		scan.Branches[len(lines)] = branches
	}
	return segs
}

func hasAt(s, p string, i int) bool {
	return len(p) > 0 && i+len(p) <= len(s) && s[i:i+len(p)] == p
}

func indexFrom(s, p string, i int) int {
	if i > len(s) {
		return -1
	}
	j := strings.Index(s[i:], p)
	if j < 0 {
		return -1
	}
	return i + j
}
