package syntax

import (
	"sync"

	ts "github.com/odvcencio/gotreesitter"
	"github.com/odvcencio/gotreesitter/grammars"
)

// PreciseMaxBytes caps the files handed to the tree-sitter parser; bigger
// files (bundles, generated code) keep the fast heuristic result.
const PreciseMaxBytes = 1 << 20

type precise struct {
	lang     *ts.Language
	outliner *ts.Outliner
	parsers  sync.Pool
}

var (
	preciseMu    sync.Mutex
	preciseCache = map[string]*precise{} // by grammar name; nil = unsupported
)

func preciseFor(filename string) *precise {
	e := grammars.DetectLanguage(filename)
	if e == nil {
		return nil
	}
	preciseMu.Lock()
	defer preciseMu.Unlock()
	if p, ok := preciseCache[e.Name]; ok {
		return p
	}
	var p *precise
	if q := grammars.ResolveTagsQuery(*e); q != "" {
		lang := e.Language()
		if o, err := ts.NewOutliner(lang, q); err == nil && lang != nil {
			p = &precise{lang: lang, outliner: o}
			p.parsers.New = func() any {
				ps := ts.NewParser(lang)
				ps.SetTimeoutMicros(3_000_000)
				return ps
			}
		}
	}
	preciseCache[e.Name] = p
	return p
}

// HasPrecise reports whether a tree-sitter grammar with a tags query exists
// for the file name.
func HasPrecise(filename string) bool { return preciseFor(filename) != nil }

// PreciseScopes parses src with tree-sitter and converts its outline into
// scopes and declarations. ok is false when the language has no grammar or
// tags query, or the parse failed; callers then keep the heuristic result.
func PreciseScopes(filename string, src []byte, lines []string, scan *Scan) (scopes []Scope, decls []Decl, ok bool) {
	if len(src) > PreciseMaxBytes {
		return nil, nil, false
	}
	p := preciseFor(filename)
	if p == nil {
		return nil, nil, false
	}
	ps := p.parsers.Get().(*ts.Parser)
	defer p.parsers.Put(ps)
	tree, err := ps.Parse(src)
	if err != nil || tree == nil {
		return nil, nil, false
	}
	defer tree.Release()
	syms, _ := p.outliner.OutlineTree(tree)

	var walk func(ss []ts.OutlineSymbol, depth int)
	walk = func(ss []ts.OutlineSymbol, depth int) {
		for _, s := range ss {
			start := int32(s.Range.StartPoint.Row)
			end := int32(s.Range.EndPoint.Row)
			if s.Range.EndPoint.Column == 0 && end > start {
				end-- // range ends at the start of the next line
			}
			kind, isScope := outlineKind(s.Kind)
			if isScope && end > start && depth < MaxScopeDepth {
				sc := Scope{Name: s.Name, Kind: kind, Start: start, End: end, Depth: depth}
				if kind == ScopeFunc && int(end) < len(lines) {
					sc.Complexity = 1 + scan.BranchesIn(start, end)
					sc.Params = countParams(lines[start])
				}
				scopes = append(scopes, sc)
				walk(s.Children, depth+1)
				continue
			}
			decls = append(decls, Decl{Name: s.Name, Kind: kind, Line: int32(s.NameRange.StartPoint.Row)})
			walk(s.Children, depth)
		}
	}
	walk(syms, 0)
	return scopes, decls, true
}

func outlineKind(k string) (ScopeKind, bool) {
	switch k {
	case "function", "method", "constructor":
		return ScopeFunc, true
	case "class", "interface", "type", "enum", "record", "struct", "trait", "impl", "object":
		return ScopeType, true
	case "module", "namespace", "package":
		return ScopeNamespace, true
	case "constant", "variable", "field", "property":
		return ScopeBlock, false
	}
	return ScopeType, true
}
