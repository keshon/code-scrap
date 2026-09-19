class_name Inspector
extends RichTextLabel
## Details of the selected node: identity, metrics, and its relations as
## clickable lists (imports, importers, calls, callers).

signal node_clicked(node: int)

const LIST_MAX := 25

var _node := {}
var _rel := {}


func _ready() -> void:
	name = "Inspector"
	bbcode_enabled = true
	selection_enabled = true
	meta_underlined = false
	meta_clicked.connect(func(m): node_clicked.emit(int(str(m))))
	Style.theme_changed.connect(_render)
	Settings.changed.connect(func(id, _v):
		if id.begins_with("relations."):
			_render())
	_render()


func show_node(n: Dictionary) -> void:
	_node = n
	_render()


func clear_node() -> void:
	_node = {}
	_rel = {}
	_render()


## rel: op ("edges" | "calls") -> relations reply
func set_relations(rel: Dictionary) -> void:
	_rel = rel
	_render()


func _render() -> void:
	var n := _node
	var dim := _hex("text3")
	if n.is_empty():
		text = "[color=%s]Click a box on the map to inspect it.[/color]" % dim
		return
	var t := "[font_size=%d][b]%s[/b][/font_size] [color=%s]· %s[/color]\n" % [int(Style.num("font", "size_title", 15)), _esc(n.name), dim, n.kind]
	t += "[color=%s]%s[/color]\n" % [_hex("text2"), _esc(n.path)]
	if n.kind != "dir":
		t += "line %d\n" % int(n.line)
	t += "%s source lines · %s bytes\n" % [Fmt.num(n.lines), Fmt.num(n.bytes)]
	t += "%s children · %s descendants\n" % [Fmt.num(n.children), Fmt.num(n.descendants)]
	if n.has("lang"):
		t += "\n[color=%s]language[/color]  %s%s\n" % [dim, n.lang, "" if not n.get("precise", false) else "  (tree-sitter)"]
	if n.has("classes") and n.classes != null and n.classes.size() > 0:
		t += "[color=%s]class[/color]  %s\n" % [dim, ", ".join(n.classes)]
	if n.has("scope"):
		t += "[color=%s]scope[/color]  %s\n" % [dim, n.scope]
	t += "\n"
	if n.has("fileMetrics"):
		var fm: Dictionary = n.fileMetrics
		t += "[b]File metrics[/b]\n"
		t += "functions  %d\nmax complexity  %d\n" % [int(fm.functions), int(fm.maxComplexity)]
		if fm.has("commits"):
			var last := "—"
			if int(fm.lastChange) > 0:
				last = Time.get_date_string_from_unix_time(int(fm.lastChange))
			t += "commits  %d\nauthors  %d\nlast change  %s\n" % [int(fm.commits), int(fm.authors), last]
		t += "\n"
	if n.has("metrics"):
		var m: Dictionary = n.metrics
		t += "[b]Function metrics[/b]\n"
		t += "cyclomatic complexity  %d\nparameters  %d\nmax nesting  %d\nlength  %d lines\n" % [int(m.complexity), int(m.params), int(m.nesting), int(m.lines)]
	else:
		t += "[color=%s]No function metrics for this selection.[/color]\n" % dim
	if _rel.has("edges"):
		t += "\n[b]Imports[/b]\n"
		t += _list(_rel.edges, "out", "imports", "relations.imports_out")
		t += _list(_rel.edges, "in", "imported by", "relations.imports_in")
	if _rel.has("calls"):
		t += "\n[b]Calls[/b] [color=%s](syntax-level)[/color]\n" % dim
		t += _list(_rel.calls, "out", "calls", "relations.calls_out")
		t += _list(_rel.calls, "in", "called by", "relations.calls_in")
	text = t


## One direction of a relation reply as a counted, clickable list.
func _list(r: Dictionary, dir: String, title: String, color_id: String) -> String:
	var edges: Array = r[dir]
	var total := int(r[dir + "Total"])
	var names: Dictionary = r.get("names", {})
	var t := "[color=%s]● %s %d[/color]\n" % [_set_hex(color_id), title, total]
	var seen := {}
	for e in edges:
		var other := int(e[1]) if dir == "out" else int(e[0])
		if seen.has(other):
			continue
		if seen.size() >= LIST_MAX:
			break
		seen[other] = true
		t += "   [url=%d]%s[/url]\n" % [other, _esc(names.get(str(other), "#%d" % other))]
	if total > seen.size():
		t += "   [color=%s]… %d more[/color]\n" % [_hex("text3"), total - seen.size()]
	return t


static func _esc(s) -> String:
	return String(s).replace("[", "[lb]")


static func _hex(token: String) -> String:
	return "#" + Style.color(token).to_html(false)


static func _set_hex(id: String) -> String:
	return "#" + (Settings.get_value(id) as Color).to_html(false)
