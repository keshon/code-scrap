package syntax

import (
	"regexp"
	"strings"
)

// ScopeKind classifies a named region of code.
type ScopeKind uint8

const (
	ScopeBlock ScopeKind = iota
	ScopeFunc
	ScopeType
	ScopeNamespace
)

func (k ScopeKind) String() string {
	return [...]string{"block", "func", "type", "namespace"}[k]
}

// Scope is a named region of a file. Lines are 0-based and inclusive.
type Scope struct {
	Name       string
	Kind       ScopeKind
	Start, End int32
	Depth      int // nesting among scopes, 0 = top level
	Complexity int32
	Params     int32
	MaxNesting int32
}

// Decl is a named declaration without a body (forward declarations,
// type aliases, top-level vars/consts).
type Decl struct {
	Name string
	Kind ScopeKind
	Line int32
}

// maxHeader caps how much text before a brace is inspected.
const maxHeader = 240

// MaxScopeDepth limits how deep scopes are tracked (namespace → type → func).
const MaxScopeDepth = 3

var (
	kwName    = regexp.MustCompile(`\b(func|fn|function|def|class|struct|interface|enum|trait|impl|namespace|module|union|object|record|message|service|type)\s+(?:class\s+|struct\s+)?(?:\([^)]*\)\s*)?([A-Za-z_$~][\w$:~]*)`)
	callName  = regexp.MustCompile(`([A-Za-z_~][\w:~]*)\s*\(`)
	indentDef = regexp.MustCompile(`^(\s*)(?:async\s+|static\s+)?(def|class|func)\s+([A-Za-z_]\w*)`)
	declRe    = regexp.MustCompile(`^\s*(?:export\s+)?(?:(class|struct|enum|union|interface)\s+([A-Za-z_]\w*)\s*;|(type|typedef|const|let|var|using)\s+([A-Za-z_$][\w$]*))`)
)

var control = map[string]bool{
	"if": true, "for": true, "while": true, "switch": true, "catch": true, "else": true, "do": true,
	"try": true, "return": true, "sizeof": true, "foreach": true, "using": true, "lock": true, "match": true,
	"loop": true, "unsafe": true, "select": true, "defer": true, "go": true, "with": true, "finally": true,
}

func kindOf(kw string) ScopeKind {
	switch kw {
	case "func", "fn", "function", "def":
		return ScopeFunc
	case "namespace", "module", "service":
		return ScopeNamespace
	}
	return ScopeType
}

// FindScopes finds named scopes and body-less declarations in a tokenized
// file. scan must come from Tokenize over the same lines.
func FindScopes(lines []string, l *Lang, scan *Scan) ([]Scope, []Decl) {
	if l.Data {
		return nil, nil
	}
	if l.Indent {
		return indentScopes(lines, scan)
	}
	return braceScopes(lines, scan)
}

var declWords = map[string]bool{
	"export": true, "class": true, "struct": true, "enum": true, "union": true, "interface": true,
	"type": true, "typedef": true, "const": true, "let": true, "var": true, "using": true,
}

func firstWord(s string) string {
	i := 0
	for i < len(s) && s[i] == ' ' {
		i++
	}
	j := i
	for j < len(s) && isIdent(s[j]) {
		j++
	}
	return s[i:j]
}

func braceScopes(lines []string, scan *Scan) ([]Scope, []Decl) {
	braces := scan.Braces
	var scopes []Scope
	type open struct {
		scope int // index into scopes, -1 if not a named scope
		depth int // brace depth before this brace
		ev    int
	}
	var stack []open
	named := 0 // named scopes currently open
	lineDepth := make([]int32, len(lines)+1)
	evDepth := make([]int32, len(braces))
	bi := 0
	depth := 0
	for li := range lines {
		lineDepth[li] = int32(depth)
		for ; bi < len(braces) && braces[bi].Line == int32(li); bi++ {
			b := braces[bi]
			if b.Open {
				idx := -1
				if named < MaxScopeDepth {
					if s, ok := headerScope(lines, b); ok {
						s.Depth = named
						idx = len(scopes)
						scopes = append(scopes, s)
						named++
					}
				}
				stack = append(stack, open{idx, depth, bi})
				depth++
				evDepth[bi] = int32(depth)
			} else {
				evDepth[bi] = int32(depth)
				if len(stack) == 0 {
					continue
				}
				o := stack[len(stack)-1]
				stack = stack[:len(stack)-1]
				depth = o.depth
				if o.scope >= 0 {
					s := &scopes[o.scope]
					s.End = int32(li)
					named--
					var mx int32
					for _, d := range evDepth[o.ev:bi] {
						mx = max(mx, d-int32(o.depth)-1)
					}
					s.MaxNesting = mx
				}
			}
		}
	}
	// scopes left open at EOF end at the last line
	for _, o := range stack {
		if o.scope >= 0 {
			scopes[o.scope].End = int32(len(lines) - 1)
		}
	}
	out := scopes[:0]
	for _, s := range scopes {
		if s.End > s.Start {
			if s.Kind == ScopeFunc {
				s.Complexity = 1 + scan.BranchesIn(s.Start, s.End)
			}
			out = append(out, s)
		}
	}
	var decls []Decl
	for li, line := range lines {
		if lineDepth[li] > 1 || !declWords[firstWord(line)] {
			continue
		}
		if m := declRe.FindStringSubmatch(line); m != nil {
			if m[2] != "" {
				decls = append(decls, Decl{m[2], ScopeType, int32(li)})
			} else if !strings.Contains(line, "{") || strings.Contains(line, "=") {
				k := ScopeBlock
				if m[3] == "type" || m[3] == "typedef" || m[3] == "using" {
					k = ScopeType
				}
				decls = append(decls, Decl{m[4], k, int32(li)})
			}
		}
	}
	return out, decls
}

// headerScope looks at the text before an opening brace and decides whether
// it names a scope.
func headerScope(lines []string, b Brace) (Scope, bool) {
	li := int(b.Line)
	head := strings.TrimSpace(lines[li][max(0, int(b.Col)-maxHeader):b.Col])
	start := li
	if head == "" && li > 0 { // brace on its own line
		for start = li - 1; start > 0 && strings.TrimSpace(lines[start]) == ""; start-- {
		}
		head = strings.TrimSpace(lines[start])
	}
	// continuation lines: long parameter lists, templates, annotations
	for k := 0; k < 4 && start > 0; k++ {
		p := strings.TrimSpace(lines[start-1])
		if strings.HasSuffix(p, ",") || strings.HasSuffix(p, "(") || strings.HasSuffix(p, "&&") ||
			strings.HasPrefix(p, "template") || strings.HasPrefix(p, "@") || strings.HasPrefix(p, "#[") {
			start--
			head = p + " " + head
			continue
		}
		break
	}
	if head == "" || strings.HasSuffix(head, "=") || strings.HasSuffix(head, "(") || strings.HasSuffix(head, ",") {
		return Scope{}, false
	}
	first := head
	if i := strings.IndexAny(first, " (<:{"); i > 0 {
		first = first[:i]
	}
	if control[first] || strings.HasPrefix(head, "}") {
		return Scope{}, false
	}
	s := Scope{Start: int32(start), End: -1}
	if m := kwName.FindStringSubmatch(head); m != nil {
		s.Name, s.Kind = m[2], kindOf(m[1])
	} else if strings.Contains(head, "=") && !strings.Contains(head, "=>") {
		return Scope{}, false // initializer
	} else if ms := callName.FindAllStringSubmatch(head, -1); ms != nil {
		name := ""
		for _, m := range ms {
			if !control[m[1]] {
				name = m[1]
				break
			}
		}
		if name == "" {
			return Scope{}, false
		}
		s.Name, s.Kind = name, ScopeFunc
	} else {
		return Scope{}, false
	}
	if s.Kind == ScopeFunc {
		s.Params = countParams(head)
	}
	return s, true
}

func countParams(head string) int32 {
	i := strings.IndexByte(head, '(')
	if i < 0 {
		return 0
	}
	depth, n, any := 0, int32(1), false
	for _, c := range head[i:] {
		switch c {
		case '(', '<', '[':
			depth++
		case ')', '>', ']':
			depth--
			if depth == 0 {
				if !any {
					return 0
				}
				return n
			}
		case ',':
			if depth == 1 {
				n++
			}
		case ' ':
		default:
			if depth == 1 {
				any = true
			}
		}
	}
	return n
}

func indentOf(s string) int {
	n := 0
	for n < len(s) && s[n] == ' ' {
		n++
	}
	return n
}

func indentScopes(lines []string, scan *Scan) ([]Scope, []Decl) {
	var scopes []Scope
	type open struct {
		idx, indent int
	}
	var stack []open
	lastCode := -1
	closeTo := func(indent int) {
		for len(stack) > 0 && stack[len(stack)-1].indent >= indent {
			o := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			scopes[o.idx].End = int32(max(lastCode, int(scopes[o.idx].Start)))
		}
	}
	for li, line := range lines {
		t := strings.TrimSpace(line)
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		ind := indentOf(line)
		closeTo(ind)
		if m := indentDef.FindStringSubmatch(line); m != nil && len(stack) < MaxScopeDepth {
			k := ScopeFunc
			if m[2] == "class" {
				k = ScopeType
			}
			stack = append(stack, open{len(scopes), ind})
			scopes = append(scopes, Scope{Name: m[3], Kind: k, Start: int32(li), Depth: len(stack) - 1})
		}
		lastCode = li
	}
	closeTo(-1)
	out := scopes[:0]
	for _, s := range scopes {
		if s.End > s.Start {
			if s.Kind == ScopeFunc {
				s.Complexity = 1 + scan.BranchesIn(s.Start, s.End)
				s.Params = countParams(lines[s.Start])
			}
			out = append(out, s)
		}
	}
	return out, nil
}
