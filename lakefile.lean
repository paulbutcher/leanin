import Lake
open System Lake DSL

package leanin where
  version := v!"0.1.0"
  description := "A concurrency runtime and work-stealing scheduler for Lean 4: Tokio's algorithms, an async that compiles to data rather than closures, and machine-checked proofs for the properties that matter."
  keywords := #["concurrency", "scheduler", "async", "runtime", "software-verification", "ffi"]
  license := "Apache-2.0"
  licenseFiles := #["LICENSE", "NOTICE"]

@[default_target] lean_lib LeanIn

/-- The socket shim: `c/netuv.c` compiled and archived by Lake rather than by the dev shell, so that a plain
`lake build` produces it and no store path appears in any build flag. Lake traces the source, so editing the C
rebuilds the object and relinks everything that uses it. -/
extern_lib netuv pkg := do
  let srcJob ← inputFile (pkg.dir / "c" / "netuv.c") true
  let oJob ← buildO (pkg.buildDir / "c" / "netuv.o") srcJob
    #["-fPIC", s!"-I{← getLeanIncludeDir}"] #["-O2"]
  buildStaticLib (pkg.buildDir / "lib" / nameToStaticLib "netuv") #[oJob]

/-- Link arguments for the socket layer: the shim Lake builds above (at the package's own build directory), and
the `libuv` it wraps, which stays a system dependency -- `uv.h` and `-luv` are needed to link it at all. -/
def netuvLinkArgs : Array String := #["-L", ".lake/build/lib", "-lnetuv", "-luv"]

@[default_target] lean_exe spike where root := `LeanIn.Exe.Spike

@[default_target] lean_exe wakerspike where root := `LeanIn.Exe.WakerSpike

@[default_target] lean_exe controls where
  root := `LeanIn.Exe.Controls
  moreLinkArgs := netuvLinkArgs

@[default_target] lean_exe dynamics where root := `LeanIn.Exe.Dynamics

@[default_target] lean_exe bridgecontrols where root := `LeanIn.Exe.BridgeControls

@[default_target] lean_exe server where
  root := `LeanIn.Exe.Server
  moreLinkArgs := netuvLinkArgs

lean_exe defuncEcho where
  root := `LeanIn.Exe.DefuncEcho
  moreLinkArgs := netuvLinkArgs

lean_exe stdServer where
  root := `LeanIn.Exe.StdServer
  moreLinkArgs := #["-luv"]

lean_exe h1bench where root := `LeanIn.Exe.H1Bench
