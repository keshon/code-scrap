package codemap

import (
	"path"
	"strings"

	"github.com/keshon/code-scrap/scrap/internal/syntax"
)

// FileClass is a set of flags describing how a file is shown and weighted.
type FileClass uint8

const (
	ClassBinary   FileClass = 1 << iota // no text to show
	ClassAsset                          // media, fonts, archives, source maps, lockfiles
	ClassSecret                         // never read or served
	ClassVendored                       // third-party code checked into the repo
	ClassData                           // config/data formats (json, yaml…)
	ClassMinified                       // minified or generated: very long lines
)

func (c FileClass) Has(f FileClass) bool { return c&f != 0 }

var assetExt = map[string]bool{}

func init() {
	for _, e := range strings.Fields(`.png .jpg .jpeg .gif .webp .bmp .ico .icns .tif .tiff .avif .heic .svg .psd .ai
		.sketch .fig .xcf .blend .fbx .obj .glb .gltf .mp4 .webm .mov .avi .mkv .mp3 .wav .ogg .flac .m4a .ttf .otf
		.woff .woff2 .eot .pdf .zip .gz .tgz .bz2 .xz .7z .rar .tar .jar .war .exe .dll .so .dylib .a .lib .o .obj
		.wasm .pyc .class .bin .dat .db .sqlite .map .lock .snap .pck .res .scn`) {
		assetExt[e] = true
	}
}

// Config-like extensions where "secret"/"password" in the name means the
// file likely holds one.
var configExt = map[string]bool{"": true, ".json": true, ".yaml": true, ".yml": true, ".toml": true,
	".ini": true, ".conf": true, ".cfg": true, ".config": true, ".properties": true, ".txt": true, ".xml": true}

// Name patterns whose contents must never be read: keys, certificates,
// credentials, environment files. Substring rules ("secret", "password")
// apply only to config-like files, so PasswordInput.tsx and
// password-recovery/suite.md stay readable.
func isSecret(name string) bool {
	n := strings.ToLower(name)
	ext := path.Ext(n)
	switch ext {
	case ".key", ".pem", ".p12", ".pfx", ".jks", ".keystore", ".crt", ".cer", ".der", ".kdbx", ".gpg", ".asc":
		return true
	}
	if n == ".env" || strings.HasPrefix(n, ".env.") || strings.HasPrefix(n, "id_rsa") ||
		strings.HasPrefix(n, "id_ed25519") || strings.HasPrefix(n, "id_ecdsa") || n == ".npmrc" || n == ".netrc" {
		return true
	}
	return configExt[ext] && (strings.Contains(n, "secret") || strings.Contains(n, "credential") || strings.Contains(n, "password"))
}

var vendorDirs = []string{"vendor/", "vendors/", "third_party/", "third-party/", "thirdparty/", "external/", "extern/", "deps/"}

func isVendored(p string) bool {
	lp := "/" + strings.ToLower(p)
	for _, d := range vendorDirs {
		if strings.Contains(lp, "/"+d) {
			return true
		}
	}
	base := path.Base(lp)
	return strings.Contains(base, ".min.") || strings.HasSuffix(base, "-min.js") || strings.HasSuffix(base, ".bundle.js")
}

// Classify decides a file's class from its path alone.
func Classify(p string, l *syntax.Lang) FileClass {
	name := path.Base(p)
	var c FileClass
	if isSecret(name) {
		return ClassSecret | ClassBinary
	}
	if assetExt[strings.ToLower(path.Ext(name))] {
		c |= ClassAsset
	}
	if isVendored(p) {
		c |= ClassVendored
	}
	if l.Data {
		c |= ClassData
	}
	return c
}
