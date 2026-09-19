class_name Fmt
## Small text formatting helpers shared by UI components.


## 1849427 → "1 849 427"
static func num(v) -> String:
	var s := str(int(v))
	var out := ""
	var n := s.length()
	for i in n:
		out += s[i]
		var left := n - 1 - i
		if left > 0 and left % 3 == 0:
			out += " "
	return out


static func short_path(p: String, max_len := 52) -> String:
	return p if p.length() <= max_len else "…" + p.right(max_len - 1)
