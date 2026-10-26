// The go.mod files Go reads to resolve a workspace's module graph.
//
// In workspace mode Go loads the go.mod of every module version the `use`
// modules require, including versions MVS doesn't select. A Nix build that
// runs Go in workspace mode without network needs all of them, but not their
// sources: they are fetched in one fixed-output derivation whose hash lives
// in the lock.
package main

import (
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
)

type goGraphLock struct {
	// .mod files relative to a GOPROXY root: <escaped module>/@v/<version>.mod
	Mods []string `toml:"mods"`
	Hash string   `toml:"hash"`
}

// analyzeGraph runs `go list -m all` against an empty module cache, served from
// the module cache the generator already filled, and records every .mod Go
// read. The hash is computed over the same layout the fetcher produces.
func analyzeGraph(directory string, prev *goGraphLock) (*goGraphLock, error) {
	gomodcache, err := exec.Command("go", "env", "GOMODCACHE").Output()
	if err != nil {
		return nil, fmt.Errorf("go env GOMODCACHE: %w", err)
	}
	upstream := filepath.Join(strings.TrimSpace(string(gomodcache)), "cache", "download")

	tmp, err := os.MkdirTemp("", "gobuild-nix-graph")
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = filepath.WalkDir(tmp, func(path string, d fs.DirEntry, err error) error {
			if err == nil {
				_ = os.Chmod(path, 0o755)
			}
			return nil
		})
		os.RemoveAll(tmp)
	}()

	cmd := exec.Command("go", "list", "-m", "all")
	cmd.Dir = directory
	cmd.Env = append(os.Environ(),
		"GOMODCACHE="+filepath.Join(tmp, "mod"),
		"GOPROXY=file://"+upstream,
		"GOSUMDB=off",
		"GOFLAGS=-mod=readonly",
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		return nil, fmt.Errorf("go list -m all: %w\n%s", err, out)
	}

	download := filepath.Join(tmp, "mod", "cache", "download")
	var mods []string
	err = filepath.WalkDir(download, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() && strings.HasSuffix(path, ".mod") && filepath.Base(filepath.Dir(path)) == "@v" {
			rel, err := filepath.Rel(download, path)
			if err != nil {
				return err
			}
			mods = append(mods, filepath.ToSlash(rel))
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	slices.Sort(mods)

	if prev != nil && slices.Equal(prev.Mods, mods) && prev.Hash != "" {
		return &goGraphLock{Mods: mods, Hash: prev.Hash}, nil
	}

	// Same tree as the fetcher's $out: only the .mod files, at their path.
	layout := filepath.Join(tmp, "layout")
	for _, rel := range mods {
		dst := filepath.Join(layout, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return nil, err
		}
		contents, err := os.ReadFile(filepath.Join(download, filepath.FromSlash(rel)))
		if err != nil {
			return nil, err
		}
		if err := os.WriteFile(dst, contents, 0o644); err != nil {
			return nil, err
		}
	}

	out, err := exec.Command("nix", "--extra-experimental-features", "nix-command", "hash", "path", "--sri", layout).Output()
	if err != nil {
		return nil, fmt.Errorf("nix hash path: %w", err)
	}

	return &goGraphLock{Mods: mods, Hash: strings.TrimSpace(string(out))}, nil
}
