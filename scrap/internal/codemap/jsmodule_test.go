package codemap

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestParseJSModule(t *testing.T) {
	src := []byte(`import {Hub, type HubId, DataObjectId as Id} from 'yougile-model'
import React, {useState} from 'react'
import * as util from './util'
import * as unused from './unused'
import './side-effect'
const lazy = import('./lazy')
export * from './a'
export * as ns from './b'
export {default as Button, Size} from './button'
export type {Context} from './context'
export const answer = util.sum(1, util.two)
export default function main() {}
export async function load() {}
interface Local {}
export {Local, Hub as Renamed}
`)
	js := parseJSModule(src)
	wantUses := map[string][]string{
		"yougile-model": {"DataObjectId", "Hub", "HubId"},
		"react":         {"default", "useState"},
		"./util":        {"sum", "two"},
		"./unused":      {"*"},
		"./side-effect": {"*"},
		"./lazy":        {"*"},
		"./a":           {"*"},
		"./b":           {"*"},
		"./button":      {"Size", "default"},
		"./context":     {"Context"},
	}
	if !reflect.DeepEqual(js.Uses, wantUses) {
		t.Errorf("uses\n got %v\nwant %v", js.Uses, wantUses)
	}
	if want := []string{"Local", "Renamed", "answer", "default", "load"}; !reflect.DeepEqual(js.Exports, want) {
		t.Errorf("exports %v, want %v", js.Exports, want)
	}
	wantRe := []jsReExport{{"./a", "*", ""}, {"./b", "*", "ns"}, {"./button", "default", "Button"},
		{"./button", "Size", "Size"}, {"./context", "Context", "Context"}}
	if !reflect.DeepEqual(js.ReExports, wantRe) {
		t.Errorf("re-exports\n got %v\nwant %v", js.ReExports, wantRe)
	}
}

func TestBarrelDeps(t *testing.T) {
	files := map[string]string{
		"app.ts":             "import {Hub, Size, Btn, ns, Missing} from './model'\nimport * as m from './model'\nm.Chat()\n",
		"model/index.ts":     "export * from './hub'\nexport * from './chat'\nexport {default as Btn, Size} from './ui/button'\nexport * as ns from './ns'\nexport * from './index'\n",
		"model/hub.ts":       "export class Hub {}\n",
		"model/chat.ts":      "export function Chat() {}\n",
		"model/ui/button.ts": "export default function Button() {}\nexport type Size = number\n",
		"model/ns.ts":        "export const x = 1\n",
	}
	m := buildFixture(t, files)
	var app int32 = -1
	for _, f := range m.Files {
		if f.Path == "app.ts" {
			app = f.Node
		}
	}
	got := map[string]bool{}
	for _, t := range m.Deps.Out[app] {
		got[m.Path(t)] = true
	}
	want := map[string]bool{"model/hub.ts": true, "model/chat.ts": true, "model/ui/button.ts": true, "model/ns.ts": true, "model/index.ts": true}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("app.ts imports %v, want %v", got, want)
	}
	if m.Deps.ViaBarrel != 4 {
		t.Errorf("via barrel %d, want 4", m.Deps.ViaBarrel)
	}
}

func buildFixture(t *testing.T, files map[string]string) *Map {
	t.Helper()
	root := t.TempDir()
	for p, body := range files {
		abs := filepath.Join(root, filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(abs, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	m, err := Build(root, Options{NoGit: true})
	if err != nil {
		t.Fatal(err)
	}
	return m
}
