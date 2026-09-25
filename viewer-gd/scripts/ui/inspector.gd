class_name Inspector
extends RichTextLabel
## What is selected, in the order a reader asks for it: what this is, what is
## inside it, what it is wired to, and what its history says. Every row that
## names something is a link that selects and frames it.

signal node_clicked(node: int)

const LIST_MAX := 25     # relation rows per direction
const OUTLINE_MAX := 14  # rows before "… n more"

var _node := {}
var _rel := {}
var _outline := []       # the selected node's children (op "children" items)
var _outline_of := -1    # which node they belong to
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
	if int(n.get("node", -1)) != _outline_of:
		_outline = []
		_outline_of = -1
	_render()


func clear_node() -> void:
	_node = {}
	_rel = {}
	_outline = []
	_outline_of = -1
	_render()


## The selected node's children, for the outline (op "children" reply).
func set_outline(node: int, items: Array) -> void:
	_outline_of = node
	_outline = items
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
	if n.is_empty():
		text = "[color=%s]Click a box on the map to inspect it.[/color]" % _hex("text3")
		return
	targets = []
	text = _head(n) + _inside(n) + _relations() + _history(n)


## Name, what it is, where it lives, and the shape of it in one line.
func _head(n: Dictionary) -> String:
	var dim := _hex("text3")
	var t := "[font_size=%d][b]%s[/b][/font_size]  [color=%s]%s[/color]\n" % [
		int(Style.num("font", "size_title", 15)), _esc(n.name), dim, n.get("scope", n.kind)]
	var where := str(n.path)
	if n.kind == "scope":   # a file always starts at line 1: saying so is noise
		where += ":%d" % int(n.line)
	t += "[color=%s]%s[/color]\n" % [_hex("text2"), _esc(where)]
	var bits := ["%s lines" % Fmt.num(n.lines)]
	if n.kind == "dir":
		bits.append("%s items" % Fmt.num(n.children))
		bits.append("%s inside" % Fmt.num(n.descendants))
	if n.has("fileMetrics"):
		var fm: Dictionary = n.fileMetrics
		bits.append("%d functions" % int(fm.functions))
		bits.append("max complexity %d" % int(fm.maxComplexity))
	if n.has("metrics"):
		var m: Dictionary = n.metrics
		bits.append("%d params" % int(m.params))
		bits.append("complexity %d" % int(m.complexity))
		bits.append("nesting %d" % int(m.nesting))
	if n.has("lang"):
		bits.append(str(n.lang))
	return t + "[color=%s]%s[/color]\n" % [_hex("text2"), " · ".join(bits)]


## What this holds: a file's functions and types with the line each starts
## on, a folder's contents with their size. An editor's outline.
func _inside(n: Dictionary) -> String:
	if _outline.is_empty():
		return ""
	var dim := _hex("text3")
	var rows := _outline.duplicate()
	var scopes: bool = n.kind != "dir"
	if scopes:   # reading order, not the order the layout put them in
		rows.sort_custom(func(a, b): return int(a.get("line", 0)) < int(b.get("line", 0)))
	var t := "\n[b]Inside[/b]  [color=%s]%d[/color]" % [dim, rows.size()]
	if not scopes:
		t += "  [color=%s]lines each[/color]" % dim
	if scopes and not n.get("precise", false):
		t += "  [color=%s]read by pattern, not parsed[/color]" % dim
	t += "\n[table=2]"
	for i in mini(rows.size(), OUTLINE_MAX):
		var r: Dictionary = rows[i]
		# the left column is an address in a file, or a size in a folder
		var lead := Fmt.num(r.get("lines", 0))
		if scopes:
			lead = str(int(r.get("line", 0)))
		var tail := "[url=%d]%s[/url]" % [int(r.node), _esc(r.name)]
		var kind := str(r.get("scope", r.kind))
		if kind != "func" and kind != "file":
			tail += "  [color=%s]%s[/color]" % [dim, kind]
		elif int(r.get("complexity", 0)) >= 10:
			tail += "  [color=%s]complexity %d[/color]" % [dim, int(r.complexity)]
		t += "[cell][color=%s]%s[/color]  [/cell][cell]%s[/cell]" % [dim, lead, tail]
	t += "[/table]\n"
	if rows.size() > OUTLINE_MAX:
		t += "[color=%s]   … %d more, on the map and in the Explorer[/color]\n" % [
			dim, rows.size() - OUTLINE_MAX]
	return t


## What this reaches for and what reaches for it. Every row is an address:
## the file and the line the relation lands on.
func _relations() -> String:
	if _rel.is_empty():
		return ""
	var dim := _hex("text3")
	var base: String = str(_node.get("path", ""))
	if _node.get("kind", "") != "dir":
		base = base.get_base_dir()
	var t := ""
	# imports belong to a file, so a selected function is shown its file's:
	# the heading says whose they are rather than pretending they are its own
	var of := ""
	if _node.get("kind", "") == "scope":
		of = " (%s)" % str(_node.get("path", "")).get_file()
	if _rel.has("edges"):
		t += _list(_rel.edges, "out", "Imports" + of, "relations.imports_out", base)
		t += _list(_rel.edges, "in", "Imported by" + of, "relations.imports_in", base)
	if _rel.has("calls"):
		t += _list(_rel.calls, "out", "Calls", "relations.calls_out", base)
		t += _list(_rel.calls, "in", "Called by", "relations.calls_in", base)
	if t == "" or targets.is_empty():
		return t
	var anchor := (" of %s" % _esc(_anchor)) if _anchor != "" else ""
	return t + "\n[color=%s]   [lb] and ] step through them%s[/color]\n" % [dim, anchor]


## The file's git line, and the cluster it belongs to.
func _history(n: Dictionary) -> String:
	var dim := _hex("text3")
	var t := ""
	var fm: Dictionary = n.get("fileMetrics", {})
	if fm.has("commits"):
		var bits := ["%s commits" % Fmt.num(fm.commits), "%s authors" % Fmt.num(fm.authors)]
		if int(fm.lastChange) > 0:
			bits.append("last change " + Time.get_date_string_from_unix_time(int(fm.lastChange)))
		t += "\n[b]History[/b]\n[color=%s]   %s[/color]\n" % [_hex("text2"), " · ".join(bits)]
	if n.has("cluster"):
		var c := _cluster(n.cluster, dim)
		if c != "":
			t += ("" if t != "" else "\n") + c
	return t


## One direction of a relation reply, as a counted list of addresses. An
## empty direction says so in one quiet line rather than a heading of its own.
func _list(r: Dictionary, dir: String, title: String, color_id: String, base := "") -> String:
	var edges: Array = r[dir]
	var total := int(r[dir + "Total"])
	var dim := _hex("text3")
	if total == 0:
		return "[color=%s]%s  none[/color]\n" % [dim, title]
	var names: Dictionary = r.get("names", {})
	var t := "\n[b]%s[/b]  [color=%s]%d[/color]\n" % [title, _set_hex(color_id), total]
	var seen := {}
	for e in edges:
		var other := int(e[1]) if dir == "out" else int(e[0])
		if seen.has(other):
			continue
		if seen.size() >= LIST_MAX:
			break
		var line := int(e[3]) if dir == "out" else int(e[2])
		seen[other] = true
		var mark := ">" if targets.size() == cursor else " "
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
		if line >= 0:
			trail += ":%d" % (line + 1)
		t += " %s [url=%d]%s[/url]" % [mark, other, _esc(lead)]
		if trail != "":
			t += "  [color=%s]%s[/color]" % [dim, _esc(trail)]
		t += "\n"
	if total > seen.size():
		t += "   [color=%s]… %d more[/color]\n" % [dim, total - seen.size()]
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
		return "[color=%s]   cluster[/color]  %s\n" % [dim, _cluster_link(c.of)]
	if c.get("hub", false):
		return "[color=%s]   cluster[/color]  [color=%s]■[/color] hub · imported by much of the code\n" % [dim, _rgb(c.color)]
	if c.get("none", false):
		return ""
	var parts: Array = c.get("parts", []) if c.get("parts") != null else []
	if parts.is_empty():
		return ""
	var t := "[color=%s]   clusters[/color]  %d, over %s clustered files\n" % [dim, int(c.spread), Fmt.num(c.clustered)]
	for p in parts:
		var share := "%d%%" % int(round(float(p.share) * 100.0))
		if p.get("hub", false):
			t += "      %s  [color=%s]■[/color] hubs\n" % [share, _rgb(p.color)]
		else:
			t += "      %s  %s\n" % [share, _cluster_link(p)]
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
