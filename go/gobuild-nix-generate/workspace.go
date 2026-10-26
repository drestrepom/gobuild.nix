// Per-module dependency analysis for Go workspaces.
//
// In a workspace each `use` module should only receive the third-party modules
// it actually imports, and each third-party module should only build the
// packages the workspace imports from it (instead of `<module>/...`).
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"

	"golang.org/x/mod/modfile"
)

// Platforms whose build constraints are taken into account. Dependencies are
// the union of all of them so the same lock works on every platform.
var workspaceGOOS = []string{"linux", "darwin"}

// A workspace `use` module and the third-party modules it needs.
type goWorkspaceLock struct {
	Require     []string `toml:"require,omitempty"`
	TestRequire []string `toml:"testRequire,omitempty"`
}

type goListDep struct {
	ImportPath string
	Standard   bool
	Imports    []string
	Module     *struct {
		Path string
		Main bool
	}
}

// listDeps returns the dependency closure of the packages under `dir` as
// (import path, module path) pairs, excluding the standard library and
// workspace modules. `imports` collects the third-party modules each
// third-party module imports from.
func listDeps(directory string, dir string, goos string, test bool, imports map[string]map[string]struct{}) (map[string]string, error) {
	args := []string{"list", "-e", "-deps", "-json=ImportPath,Standard,Imports,Module"}
	if test {
		args = append(args, "-test")
	}
	args = append(args, "./"+dir+"/...")

	cmd := exec.Command("go", args...)
	cmd.Dir = directory
	cmd.Env = append(os.Environ(), "GOOS="+goos)
	stdout, err := cmd.Output()
	if err != nil {
		if exiterr, ok := err.(*exec.ExitError); ok {
			return nil, fmt.Errorf("go list in %s (GOOS=%s): %s\n%s", dir, goos, exiterr, exiterr.Stderr)
		}
		return nil, fmt.Errorf("go list in %s (GOOS=%s): %w", dir, goos, err)
	}

	deps := make(map[string]string)
	var pkgs []goListDep
	dec := json.NewDecoder(bytes.NewReader(stdout))
	for {
		var pkg goListDep
		if err := dec.Decode(&pkg); err == io.EOF {
			break
		} else if err != nil {
			return nil, err
		}

		if pkg.Standard || pkg.Module == nil || pkg.Module.Main {
			continue
		}

		// Test variants are listed as "pkg [pkg.test]"; the package is the same.
		importPath, _, _ := strings.Cut(pkg.ImportPath, " ")
		deps[importPath] = pkg.Module.Path
		pkgs = append(pkgs, pkg)
	}

	for _, pkg := range pkgs {
		for _, imp := range pkg.Imports {
			impPath, _, _ := strings.Cut(imp, " ")
			modPath, ok := deps[impPath]
			if !ok || modPath == pkg.Module.Path {
				continue
			}
			if imports[pkg.Module.Path] == nil {
				imports[pkg.Module.Path] = make(map[string]struct{})
			}
			imports[pkg.Module.Path][modPath] = struct{}{}
		}
	}

	return deps, nil
}

func sortedKeys(m map[string]struct{}) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}

// analyzeWorkspace fills `Workspace` (per `use` module) and `Packages` (per
// locked module). It is a no-op outside of a workspace.
func analyzeWorkspace(directory string, lock *lockFile) error {
	workPath := filepath.Join(directory, WORK_FILE)
	contents, err := os.ReadFile(workPath)
	if os.IsNotExist(err) {
		return nil
	} else if err != nil {
		return fmt.Errorf("error reading go.work: %w", err)
	}

	work, err := modfile.ParseWork(workPath, contents, nil)
	if err != nil {
		return fmt.Errorf("error parsing go.work: %w", err)
	}

	packages := make(map[string]map[string]struct{})
	addPackages := func(deps map[string]string) {
		for importPath, modPath := range deps {
			if packages[modPath] == nil {
				packages[modPath] = make(map[string]struct{})
			}
			packages[modPath][importPath] = struct{}{}
		}
	}

	imports := make(map[string]map[string]struct{})

	lock.Workspace = make(map[string]*goWorkspaceLock)
	for _, use := range work.Use {
		dir := filepath.Clean(use.Path)

		require := make(map[string]struct{})
		testRequire := make(map[string]struct{})
		for _, goos := range workspaceGOOS {
			prod, err := listDeps(directory, dir, goos, false, imports)
			if err != nil {
				return err
			}
			addPackages(prod)
			for _, modPath := range prod {
				require[modPath] = struct{}{}
			}

			test, err := listDeps(directory, dir, goos, true, imports)
			if err != nil {
				return err
			}
			addPackages(test)
			for _, modPath := range test {
				testRequire[modPath] = struct{}{}
			}
		}

		for modPath := range require {
			delete(testRequire, modPath)
		}

		lock.Workspace[dir] = &goWorkspaceLock{
			Require:     sortedKeys(require),
			TestRequire: sortedKeys(testRequire),
		}
	}

	// In a workspace, modules depend on what their used packages import, not
	// on their go.mod requirements: those are a superset (adapters, tests,
	// tooling) that only module resolution needs, and they form cycles the
	// import graph doesn't have (grpc -> s2a-go -> cloud.google.com/go -> grpc).
	for modPath, locked := range lock.Locked {
		locked.Packages = sortedKeys(packages[modPath])
		locked.Require = sortedKeys(imports[modPath])
	}

	for modPath := range packages {
		if _, ok := lock.Locked[modPath]; !ok {
			return fmt.Errorf("module %s is imported by the workspace but missing from the lock", modPath)
		}
	}

	return nil
}
