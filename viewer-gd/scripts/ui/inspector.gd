class_name Inspector
extends RichTextLabel
## Details of the selected node: identity, metrics, and its relations as
## clickable lists (imports, importers, calls, callers).

signal node_clicked(node: int)

const LIST_MAX := 25

var _node := {}
var _rel := {}
var _anchor := ""        # the node whose relations are listed (while stepping)
var targets: Array[int] = []   # relation endpoints in list order ([ and ] step)
var cursor := -1


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


## rel: op ("edges" | "calls") -> relations reply. anchor: the name of the
## node they belong to when it is not the one shown (stepping through them).
func set_relations(rel: Dictionary, anchor := "") -> void:
	_rel = rel
	_anchor = anchor
	cursor = -1
	_render()


## Moves the relations cursor (1 next, -1 previous); returns the node to
## go to, or -1.
func step(d: int) -> int:
	if targets.is_empty():
		return -1
	cursor = posmod(cursor + d, targets.size())
	_render()
	return targets[cursor]


func _render() -> void:
	var n := _node
	var dim := _hex("text3")
	if n.is_empty():
		text = "[color=%s]Click a box on the map to inspect it.[/color]" % dim
		return
	# identity first, then what it is joined to, then the numbers: the
	# relations are why this panel exists, so they sit above the metrics
	var t := "[font_size=%d][b]%s[/b][/font_size]  [color=%s]%s[/color]
" % [
		int(Style.num("font", "size_title", 15)), _esc(n.name), dim, n.get("scope", n.kind)]
	t += "[color=%s]%s%s[/color]
" % [_hex("text2"), _esc(n.path),
		"" if n.kind == "dir" else ":%d" % int(n.line)]
	t += "
%s
" % _facts(n, dim)
	if n.has("cluster"):
		t += _cluster(n.cluster, dim)
	targets = []
	var rel := _relations(dim)
	if rel != "":
		t += "
" + rel
	var metrics := _metrics(n, dim)
	if metrics != "":
		t += "
" + metrics
	text = t


## The one-line facts: size, and what kind of thing this is.
func _facts(n: Dictionary, dim: String) -> String:
	var bits := ["%s lines" % Fmt.num(n.lines)]
	if n.kind == "dir":
		bits.append("%s items" % Fmt.num(n.children))
		bits.append("%s inside" % Fmt.num(n.descendants))
	elif int(n.get("bytes", 0)) > 0:
		bits.append("%s bytes" % Fmt.num(n.bytes))
	if n.has("lang"):
		bits.append(str(n.lang) + ("" if not n.get("precise", false) else " · tree-sitter"))
	if n.has("classes") and n.classes != null and n.classes.size() > 0:
		bits.append(", ".join(n.classes))
	return "[color=%s]%s[/color]" % [_hex("text2"), " · ".join(bits)]


## Imports and calls, with the hint about stepping only when there is
## something to step through.
func _relations(dim: String) -> String:
	if _rel.is_empty():
		return ""
	# paths are shown from the folder we are standing in, so a neighbour
	# reads as its bare name and only the distant ones carry a path
	var base: String = str(_node.get("path", ""))
	if _node.get("kind", "") != "dir":
		base = base.get_base_dir()
	var t := ""
	if _rel.has("edges"):
		t += "[b]Imports[/b]
"
		t += _list(_rel.edges, "out", "imports", "relations.imports_out", base)
		t += _list(_rel.edges, "in", "importers", "relations.imports_in", base)
	if _rel.has("calls"):
		t += "
[b]Calls[/b] [color=%s]syntax-level[/color]
" % dim
		t += _list(_rel.calls, "out", "calls", "relations.calls_out", base)
		t += _list(_rel.calls, "in", "callers", "relations.calls_in", base)
	if t == "":
		return ""
	if targets.is_empty():
		return t
	var of := (" of %s" % _esc(_anchor)) if _anchor != "" else ""
	return t + "
[color=%s][lb] and ] step through the list%s[/color]
" % [dim, of]


## Metrics last, as label/value pairs rather than sentences.
func _metrics(n: Dictionary, dim: String) -> String:
	var rows := []
	if n.has("fileMetrics"):
		var fm: Dictionary = n.fileMetrics
		rows.append(["functions", str(int(fm.functions))])
		rows.append(["max complexity", str(int(fm.maxComplexity))])
		if fm.has("commits"):
			var last := "—"
			if int(fm.lastChange) > 0:
				last = Time.get_date_string_from_unix_time(int(fm.lastChange))
			rows.append(["commits", "%d by %d" % [int(fm.commits), int(fm.authors)]])
			rows.append(["last change", last])
	if n.has("metrics"):
		var m: Dictionary = n.metrics
		rows.append(["complexity", str(int(m.complexity))])
		rows.append(["parameters", str(int(m.params))])
		rows.append(["max nesting", str(int(m.nesting))])
		rows.append(["length", "%d lines" % int(m.lines)])
	if rows.is_empty():
		return ""
	var t := "[b]Metrics[/b]
"
	for r in rows:
		t += "[color=%s]%s[/color]  %s
" % [dim, r[0], r[1]]
	return t


## One direction of a relation reply as a counted, clickable list. The name
## leads and its path trails in a quieter colour, so a long list scans.
func _list(r: Dictionary, dir: String, title: String, color_id: String, base := "") -> String:
	var edges: Array = r[dir]
	var total := int(r[dir + "Total"])
	if total == 0:
		return "[color=%s]● no %s[/color]
" % [_hex("text3"), title]
	var names: Dictionary = r.get("names", {})
	var t := "[color=%s]● %s %d[/color]
" % [_set_hex(color_id), title, total]
	var seen := {}
	var last := ""   # a repeated path is left out: the row above carries it
	for e in edges:
		var other := int(e[1]) if dir == "out" else int(e[0])
		if seen.has(other):
			continue
		if seen.size() >= LIST_MAX:
			break
		seen[other] = true
		var mark := "›" if targets.size() == cursor else " "
		targets.append(other)
		var whole: String = str(names.get(str(other), "#%d" % other))
		var lead := whole
		var trail := ""
		var sep := whole.find(" · ")
		if sep > 0:   # a function: its name, then the file it lives in
			lead = whole.substr(0, sep)
			trail = _near(whole.substr(sep + 3), base)
		elif whole.contains("/"):   # a file or folder: its name, then the way there
			var near := _near(whole, base)
			lead = near.get_file()
			trail = near.get_base_dir()
		t += " %s [url=%d]%s[/url]" % [mark, other, _esc(lead)]
		if trail != "" and trail != last:
			t += "  [color=%s]%s[/color]" % [_hex("text3"), _esc(trail)]
		last = trail
		t += "
"
	if total > seen.size():
		t += "   [color=%s]… %d more[/color]
" % [_hex("text3"), total - seen.size()]
	return t


## A path as seen from base: the shared folders are dropped, so a file next
## door is just its name.
static func _near(path: String, base: String) -> String:
	if path == "" or base == "":
		return path
	var a := base.split("/")
	var b := path.split("/")
	var i := 0
	while i < a.size() and i < b.size() - 1 and a[i] == b[i]:
		i += 1
	if i == 0:
		return path
	return "/".join(Array(b).slice(i))


## A file's cluster (click frames its home folder), or the clusters a
## folder's files belong to.
func _cluster(c: Dictionary, dim: String) -> String:
	if c.has("of"):
		return "[color=%s]cluster[/color]  %s\n" % [dim, _cluster_link(c.of)]
	if c.get("hub", false):
		return "[color=%s]cluster[/color]  [color=%s]■[/color] hub · imported by much of the code\n" % [dim, _rgb(c.color)]
	if c.get("none", false):
		return "[color=%s]cluster  none[/color]\n" % dim
	var parts: Array = c.get("parts", []) if c.get("parts") != null else []
	if parts.is_empty():
		return ""
	var t := "[color=%s]clusters[/color]  %d, over %s clustered files\n" % [dim, int(c.spread), Fmt.num(c.clustered)]
	for p in parts:
		var share := "%d%%" % int(round(float(p.share) * 100.0))
		if p.get("hub", false):
			t += "   %s  [color=%s]■[/color] hubs\n" % [share, _rgb(p.color)]
		else:
			t += "   %s  %s\n" % [share, _cluster_link(p)]
	return t


static func _cluster_link(p: Dictionary) -> String:
	var name := str(p.name) if str(p.name) != "" else "unnamed"
	return "[color=%s]■[/color] [url=%d]%s[/url]" % [_rgb(p.color), int(p.home), _esc(name)]


static func _rgb(c: Array) -> String:
	return "#" + Color(c[0], c[1], c[2]).to_html(false)


static func _esc(s) -> String:
	return String(s).replace("[", "[lb]")


static func _hex(token: String) -> String:
	return "#" + Style.color(token).to_html(false)


static func _set_hex(id: String) -> String:
	return "#" + (Settings.get_value(id) as Color).to_html(false)
