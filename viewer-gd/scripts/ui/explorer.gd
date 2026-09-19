class_name Explorer
extends PanelContainer
## Left zone (optional, top bar toggle): the repository as a tree, like an
## editor's explorer. Folders and files load lazily; a file expands into its
## functions and classes. Clicking selects and frames on the map; the tree
## follows the selection made anywhere else.

signal node_chosen(node: int)

var client: ScrapClient
var _tree: Tree
var _item_of := {}       # node id -> TreeItem
var _loaded := {}        # node id -> true once its children are in the tree
var _reqs := {}          # request id -> node id
var _reveal := []        # node ids still to walk down to (root first)
var _revealing := false  # selecting programmatically: do not echo


func _init(c: ScrapClient) -> void:
	client = c


func _ready() -> void:
	custom_minimum_size = Vector2(240, 0)
	var vb := VBoxContainer.new()
	add_child(vb)
	var title := Label.new()
	title.theme_type_variation = "SectionLabel"
	title.text = Style.text("Explorer")
	vb.add_child(title)
	_tree = Tree.new()
	_tree.hide_root = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_collapsed.connect(_on_collapsed)
	_tree.item_selected.connect(_on_selected)
	vb.add_child(_tree)
	client.reply.connect(_on_reply)


## A new map generation: node ids changed, start over (the shell re-reveals
## the selection).
func reload() -> void:
	_tree.clear()
	_item_of = {}
	_loaded = {}
	_reqs = {}
	var root := _tree.create_item()
	root.set_metadata(0, 0)
	_item_of[0] = root
	_request(0)


## Expands the tree down to a node and selects it. path: ancestor ids from
## the root, then the node itself.
func reveal(path: Array) -> void:
	_reveal = path.duplicate()
	_continue_reveal()


func _continue_reveal() -> void:
	while not _reveal.is_empty():
		var id: int = _reveal[0]
		var it: TreeItem = _item_of.get(id)
		if it == null:
			return  # its parent is still loading
		if _reveal.size() == 1:
			_reveal = []
			_revealing = true
			it.select(0)
			_tree.scroll_to_item(it)
			_revealing = false
			return
		_reveal.pop_front()
		if not _loaded.has(id):
			_request(id)
			return
		it.collapsed = false


func _request(id: int) -> void:
	if _reqs.values().has(id):
		return
	_reqs[client.request("children", {"node": id})] = id


func _on_reply(rid: int, data: Dictionary) -> void:
	if data.get("op") != "children" or not _reqs.has(rid):
		return
	var id: int = _reqs[rid]
	_reqs.erase(rid)
	var parent: TreeItem = _item_of.get(id)
	if parent == null:
		return
	for c in parent.get_children():
		if c.get_metadata(0) == null:
			c.free()  # the "loading…" placeholder
	for x in data.items:
		var it := _tree.create_item(parent)
		var nid := int(x.node)
		it.set_text(0, str(x.name))
		it.set_metadata(0, nid)
		var icon := "folder" if x.kind == "dir" else ("file" if x.kind == "file" else "symbol")
		it.set_icon(0, Style.icon(icon, Color(x.color[0], x.color[1], x.color[2])))
		if x.kind == "scope":
			it.set_custom_color(0, Style.color("text2"))
		it.set_tooltip_text(0, "%s · %s lines" % [x.kind, Fmt.num(x.lines)])
		_item_of[nid] = it
		if int(x.kids) > 0:
			var ph := _tree.create_item(it)
			ph.set_text(0, "…")
			it.collapsed = true
	_loaded[id] = true
	if id != 0:
		parent.collapsed = false
	_continue_reveal()


func _on_collapsed(it: TreeItem) -> void:
	if it.collapsed:
		return
	var id = it.get_metadata(0)
	if id != null and not _loaded.has(int(id)):
		_request(int(id))


func _on_selected() -> void:
	if _revealing:
		return
	var it := _tree.get_selected()
	if it != null and it.get_metadata(0) != null:
		node_chosen.emit(int(it.get_metadata(0)))
