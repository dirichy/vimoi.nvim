# Render environment compatibility

> Historical investigation and design options. Managed templates inject their cat
> context as described below. `render.validate = true` now validates a fixed disk
> baseline once during source-session construction, independently of buffer edits.
> `false` skips it. All consumers, including preview, wait for construction success.
> Static put/re-add uses local source-map inference after that check. See
> [FEATURES](../FEATURES.md) and [README](../README.md) for current behavior.

The sentinel MVP renders its instrumented template with `chezmoi
execute-template` over stdin. This is intentionally simple, but it is not
identical to rendering a managed target with `chezmoi cat`.

The repository contains an executable comparison in `tests/environment.lua`
and its isolated fixture in `tests/fixtures/environment`.

## Current context injection

For managed template buffers, source_map prepends output-free `set .chezmoi`
actions to the sentinel skeleton. They supply sourceFile relative to the effective
source root, the managed absolute targetFile, command="cat", and the corresponding
cat args. Empty if bodies discard set's return value without introducing variables
into the user's scope or emitting whitespace. args retains its native []string type.
The injected values also reach includeTemplate when passed the same template data.

The entire prelude is part of the skeleton cache key. The last complete trace also
compares its prelude, so equal source text in different files cannot reuse the wrong
context. Local static inference retains the captured prelude; live-buffer rebuilds
reject a changed context, including renames. Tag skeleton offsets include the prelude,
preserving diagnostic source positions. Plain text can skip execution, but its
restored skeleton must omit the output-free prelude.

Unnamed buffers, unmanaged/source-only files, raw string traces without a buffer,
and init templates keep their native execute-template context. Templates that produce
different results under cat and apply remain unsupported; this feature simulates cat,
not apply. Source-session construction validates a disk baseline against the real read-only cat command once by default.
Regression coverage is in tests/template_context.lua and tests/diagnostic.lua.

## Empirical results

The following values behaved identically in `cat`, `execute-template` over
stdin, and `execute-template --file`:

- `.chezmoi.sourceDir`
- `.chezmoi.destDir`
- `.chezmoi.configFile`
- `.chezmoi.workingTree`
- `stdinIsATTY` when invoked as a background process
- `include` with a source-relative path

The following values differ:

| Value | `cat target` | stdin | `--file source` |
| --- | --- | --- | --- |
| `.chezmoi.sourceFile` | source-relative path | `stdin` | source-relative path |
| `.chezmoi.targetFile` | absolute target path | empty | empty |
| `.chezmoi.command` | `cat` | `execute-template` | `execute-template` |
| `.chezmoi.args` | contains `cat target` | contains `execute-template` | contains `execute-template --file source` |

`includeTemplate` itself works, but an included template observes the caller's
context. Consequently, its result can also differ when it reads
`.chezmoi.sourceFile`, `.chezmoi.targetFile`, `.chezmoi.command`, or
`.chezmoi.args`.

A full field-by-field comparison of the `.chezmoi` object found no other
differences in the isolated fixture with chezmoi 2.73.1.

Init config templates additionally require `execute-template --init` for
`prompt*Once` and related init-only functions. The diff renderer recognizes
`.chezmoi.{toml,yaml,yml,json,jsonc}.tmpl`, maps it to `.chezmoi.configFile`, and
enables this flag for every render and refresh.

## MVP policy

The following describes the historical implementation before context injection.
The initial implementation kept stdin rendering. Templates whose output
depends on `sourceFile`, `targetFile`, `command`, or `args` are explicitly
unsupported, including indirect access from `includeTemplate`. Before an
automatic merge is allowed, the tracer must compare its clean, sentinel-free
output with the real `chezmoi cat` output. A mismatch makes the trace untrusted
and disables automatic write-back.

Future options are:

1. Use a shadow source tree and `chezmoi --source <shadow> cat <target>`. This
   preserves `sourceFile` and `targetFile`, but changes `sourceDir` and possibly
   `workingTree`.
2. Add a chezmoi capability that renders supplied template contents while
   retaining the original target context. This would provide full fidelity.
3. Detect context-sensitive variables in the AST and explain the exact reason
   that tracing cannot be trusted.

## Shadow `cat` option

`chezmoi cat` only accepts managed targets; it cannot render template contents
provided through stdin. A higher-fidelity tracer can create a temporary shadow
copy of the source state, replace the target template at the same relative path
with its instrumented form, and run:

```text
chezmoi --source <shadow-source> --working-tree <real-working-tree> cat <target>
```

This preserves `sourceFile`, `targetFile`, `command`, include paths, and target
semantics. It still changes `sourceDir` and `args`, so it does not remove the
need for final equality validation. It also does not apply to
`.chezmoi.{toml,yaml,yml,json,jsonc}.tmpl`, which is an init config template rather
than a managed target.

Temporarily replacing the real source file would preserve all context, but is
not an acceptable implementation: other processes and file watchers could
observe the instrumented template, and a crash could leave the source state
modified.

Regardless of the chosen backend, equality with the real rendered base remains
the final correctness check.
