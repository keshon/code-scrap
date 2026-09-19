package codemap

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// Rule gives every file matching a glob its own importance weight, over
// the class weights. Globs match repo-relative paths: * stays within a
// folder, ** crosses folders, ? is one character.
type Rule struct {
	Glob   string  `json:"glob"`
	Weight float64 `json:"weight"`
	re     *regexp.Regexp
}

// ParseRules reads "glob = weight; glob = weight", as typed in the viewer.
func ParseRules(s string) ([]Rule, error) {
	var out []Rule
	for _, part := range strings.FieldsFunc(s, func(r rune) bool { return r == ';' || r == '\n' }) {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		g, w, ok := strings.Cut(part, "=")
		if !ok {
			return out, fmt.Errorf("rule %q: want glob = weight", part)
		}
		v, err := strconv.ParseFloat(strings.TrimSpace(w), 64)
		if err != nil {
			return out, fmt.Errorf("rule %q: %v", part, err)
		}
		out = append(out, NewRule(strings.TrimSpace(g), v))
	}
	return out, nil
}

// NewRule compiles a glob.
func NewRule(glob string, weight float64) Rule {
	var b strings.Builder
	b.WriteString("^")
	for i := 0; i < len(glob); i++ {
		switch c := glob[i]; c {
		case '*':
			if i+1 < len(glob) && glob[i+1] == '*' {
				i++
				if i+1 < len(glob) && glob[i+1] == '/' {
					i++
					b.WriteString("(?:.*/)?") // **/ = any folders, or none
				} else {
					b.WriteString(".*")
				}
			} else {
				b.WriteString("[^/]*")
			}
		case '?':
			b.WriteString("[^/]")
		default:
			b.WriteString(regexp.QuoteMeta(string(c)))
		}
	}
	b.WriteString("$")
	return Rule{Glob: glob, Weight: weight, re: regexp.MustCompile(b.String())}
}

// Match reports whether a repo-relative path matches the rule.
func (r Rule) Match(p string) bool { return r.re != nil && r.re.MatchString(p) }

// RepoRules reads importance rules from a repository's own .scrap.json:
//
//	{"importance": {"rules": {"src/legacy/**": 0.3}}}
func RepoRules(root string) []Rule {
	b, err := os.ReadFile(filepath.Join(root, ".scrap.json"))
	if err != nil {
		return nil
	}
	var cfg struct {
		Importance struct {
			Rules map[string]float64 `json:"rules"`
		} `json:"importance"`
	}
	if json.Unmarshal(b, &cfg) != nil {
		return nil
	}
	var out []Rule
	for g, w := range cfg.Importance.Rules {
		out = append(out, NewRule(g, w))
	}
	return out
}
