package syntax

import (
	"path/filepath"
	"strings"
)

// Lang describes just enough about a language to tokenize it for highlighting
// and to find its scopes heuristically. Tree-sitter can replace this later
// without changing the index format.
type Lang struct {
	Name         string
	LineComments []string
	BlockOpen    string
	BlockClose   string
	Quotes       string // single-char string delimiters
	RawQuote     byte   // multi-line raw string delimiter (e.g. '`'), 0 if none
	TripleQuote  bool   // python-style """ / '''
	Indent       bool   // scopes are defined by indentation, not braces
	Data         bool   // data/config file: rendered grey, no scopes
	Keywords     map[string]bool
	Preproc      bool // '#' at line start is a preprocessor directive
}

func kw(s string) map[string]bool {
	m := map[string]bool{}
	for _, w := range strings.Fields(s) {
		m[w] = true
	}
	return m
}

var (
	cKeywords = kw(`auto break case char const continue default do double else enum extern float for goto if inline int long
		register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while bool true false
		class namespace template typename public private protected virtual override final friend operator new delete this nullptr
		using try catch throw noexcept constexpr consteval explicit mutable static_cast dynamic_cast reinterpret_cast const_cast
		decltype concept requires co_await co_return co_yield export import module`)
	goKeywords = kw(`break case chan const continue default defer else fallthrough for func go goto if import interface map
		package range return select struct switch type var nil true false iota any error string int int8 int16 int32 int64
		uint uint8 uint16 uint32 uint64 float32 float64 bool byte rune`)
	jsKeywords = kw(`break case catch class const continue debugger default delete do else export extends finally for function
		if import in instanceof let new return super switch this throw try typeof var void while with yield async await of
		static get set null undefined true false interface type enum implements private public protected readonly abstract
		declare namespace module keyof as from any number string boolean never unknown`)
	pyKeywords = kw(`and as assert async await break class continue def del elif else except finally for from global if
		import in is lambda nonlocal not or pass raise return try while with yield None True False self match case`)
	gdKeywords = kw(`if elif else for while match break continue pass return class class_name extends is in as self signal
		func static const enum var onready export setget breakpoint preload await yield assert void true false null
		and or not super tool int float bool String Vector2 Vector3 Array Dictionary`)
	rsKeywords = kw(`as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod
		move mut pub ref return self Self static struct super trait true type unsafe use where while Box Option Result Some None Ok Err`)
	javaKeywords = kw(`abstract assert boolean break byte case catch char class const continue default do double else enum
		extends final finally float for goto if implements import instanceof int interface long native new package private
		protected public return short static strictfp super switch synchronized this throw throws transient try void volatile
		while true false null var record sealed permits yield fun val object companion data when is in out override open internal`)
	csKeywords = kw(`abstract as base bool break byte case catch char checked class const continue decimal default delegate do
		double else enum event explicit extern false finally fixed float for foreach goto if implicit in int interface internal
		is lock long namespace new null object operator out override params private protected public readonly ref return sbyte
		sealed short sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort
		using virtual void volatile while var async await record get set init value partial where yield`)
	shKeywords  = kw(`if then else elif fi case esac for while until do done in function return local export readonly declare`)
	sqlKeywords = kw(`select from where insert into update delete create table index view drop alter join left right inner outer
		on group by order having limit offset union all distinct as and or not null values set primary key foreign references
		SELECT FROM WHERE INSERT INTO UPDATE DELETE CREATE TABLE INDEX VIEW DROP ALTER JOIN LEFT RIGHT INNER OUTER ON GROUP BY
		ORDER HAVING LIMIT OFFSET UNION ALL DISTINCT AS AND OR NOT NULL VALUES SET PRIMARY KEY FOREIGN REFERENCES`)
	noKeywords = map[string]bool{}
)

var langs = map[string]*Lang{}

func reg(l *Lang, exts ...string) {
	for _, e := range exts {
		langs[e] = l
	}
}

func init() {
	cLike := func(name string, k map[string]bool) *Lang {
		return &Lang{Name: name, LineComments: []string{"//"}, BlockOpen: "/*", BlockClose: "*/", Quotes: `"'`, Keywords: k}
	}
	c := cLike("C/C++", cKeywords)
	c.Preproc = true
	reg(c, ".c", ".h", ".cc", ".cpp", ".cxx", ".hpp", ".hh", ".hxx", ".inl", ".ipp", ".m", ".mm", ".cu", ".glsl", ".hlsl", ".frag", ".vert", ".shader", ".gdshader")
	gol := cLike("Go", goKeywords)
	gol.RawQuote = '`'
	reg(gol, ".go")
	js := cLike("JavaScript/TypeScript", jsKeywords)
	js.RawQuote = '`'
	reg(js, ".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx", ".mts", ".cts", ".vue", ".svelte")
	reg(cLike("Rust", rsKeywords), ".rs")
	reg(cLike("Java/Kotlin", javaKeywords), ".java", ".kt", ".kts", ".scala", ".groovy", ".gradle", ".dart", ".swift")
	reg(cLike("C#", csKeywords), ".cs")
	reg(cLike("CSS", noKeywords), ".css", ".scss", ".less")
	reg(cLike("Protobuf", kw("syntax package import option message enum service rpc returns repeated optional required map oneof")), ".proto")

	reg(&Lang{Name: "Python", LineComments: []string{"#"}, Quotes: `"'`, TripleQuote: true, Indent: true, Keywords: pyKeywords}, ".py", ".pyi", ".pyw")
	reg(&Lang{Name: "GDScript", LineComments: []string{"#"}, Quotes: `"'`, TripleQuote: true, Indent: true, Keywords: gdKeywords}, ".gd")
	reg(&Lang{Name: "Shell", LineComments: []string{"#"}, Quotes: `"'`, Keywords: shKeywords}, ".sh", ".bash", ".zsh", ".fish", ".ps1", ".psm1")
	reg(&Lang{Name: "SQL", LineComments: []string{"--"}, BlockOpen: "/*", BlockClose: "*/", Quotes: `"'`, Keywords: sqlKeywords}, ".sql")
	reg(&Lang{Name: "Lua", LineComments: []string{"--"}, Quotes: `"'`, Keywords: kw("and break do else elseif end false for function goto if in local nil not or repeat return then true until while")}, ".lua")
	reg(&Lang{Name: "Ruby", LineComments: []string{"#"}, Quotes: `"'`, Keywords: kw("alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield")}, ".rb")
	reg(&Lang{Name: "Markup", BlockOpen: "<!--", BlockClose: "-->", Quotes: `"'`, Keywords: noKeywords}, ".html", ".htm", ".xml", ".svg", ".xhtml", ".vcxproj", ".csproj", ".plist", ".xaml", ".tscn", ".tres")
	reg(&Lang{Name: "Markdown", Quotes: "`", Keywords: noKeywords}, ".md", ".markdown", ".rst", ".txt", ".adoc")

	data := func(name string, lc ...string) *Lang {
		return &Lang{Name: name, LineComments: lc, Quotes: `"'`, Data: true, Keywords: kw("true false null yes no on off")}
	}
	reg(data("JSON"), ".json", ".jsonc", ".json5", ".geojson", ".map", ".lock", ".sum", ".mod")
	reg(data("YAML", "#"), ".yaml", ".yml")
	reg(data("TOML/INI", "#", ";"), ".toml", ".ini", ".cfg", ".conf", ".properties", ".env", ".godot", ".import", ".editorconfig")
	reg(data("CSV"), ".csv", ".tsv")
}

var plainLang = &Lang{Name: "Text", Keywords: noKeywords}

var specialNames = map[string]*Lang{
	"makefile":       {Name: "Make", LineComments: []string{"#"}, Quotes: `"'`, Keywords: noKeywords},
	"dockerfile":     {Name: "Dockerfile", LineComments: []string{"#"}, Quotes: `"'`, Keywords: kw("FROM RUN CMD COPY ADD ENV ARG WORKDIR EXPOSE ENTRYPOINT USER VOLUME LABEL")},
	"cmakelists.txt": {Name: "CMake", LineComments: []string{"#"}, Quotes: `"`, Keywords: noKeywords},
	"build.gn":       {Name: "GN", LineComments: []string{"#"}, Quotes: `"`, Keywords: noKeywords},
	"build":          {Name: "Starlark", LineComments: []string{"#"}, Quotes: `"'`, Keywords: pyKeywords},
	"deps":           {Name: "DEPS", LineComments: []string{"#"}, Quotes: `"'`, Data: true, Keywords: noKeywords},
	"license":        plainLang,
	"readme":         plainLang,
	"owners":         plainLang,
}

// For picks a language by file name.
func For(name string) *Lang {
	lower := strings.ToLower(name)
	if l, ok := specialNames[lower]; ok {
		return l
	}
	if l, ok := langs[filepath.Ext(lower)]; ok {
		return l
	}
	if strings.HasPrefix(lower, ".") { // dotfiles: .gitignore, .clang-format …
		return langs[".ini"]
	}
	return plainLang
}
