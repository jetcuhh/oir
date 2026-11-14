# AGENTS.md

The owner's philosophy is **minimalism**. Apply it to code, words, and tokens.

## Code
- Smallest change that solves the problem. No speculative features, options, or abstractions.
- Delete before adding. If something can go, it goes.
- No new dependencies unless the alternative is clearly worse. Prefer the standard library.
- Match the existing style. Don't reformat or refactor code you weren't asked to touch.
- Comments only for the *why*, never the *what*.

## Attribution
- No watermarks anywhere: commits, PRs, patches, code, docs. No `Co-Authored-By`, "Generated with", session links, robot emoji, or tool/model names. The owner is the only author.

## Words
- Answer first, in as few words as it takes. No preamble, recap, or flattery.
- Say what changed and what's next. Skip the narration.

## Tokens (this environment is metered)
- Batch commands: `a && b && c`, not three calls.
- Filter output at the source: `rg -l`, `head -n 20`, `tail -n 20`, `git diff --stat`, `git log --oneline -n 10`, `wc -l`. Never dump whole files or logs.
- Quiet flags: `-q`, `--quiet`, `--no-progress`. Spinners and progress bars waste output.
- Read line ranges (`rd FILE 40 80`), not files. Edit with small replacements, never rewrite whole files.
- Long jobs: `nohup CMD >/tmp/out/x.log 2>&1 &`, then `tail`. Long output is saved in `/tmp/out/`; search it instead of re-running.
- Don't re-read what you just wrote. Don't repeat what the user already knows.

## Doing the work
- Ask only when a wrong guess is expensive. Otherwise pick the sensible default and say so in one line.
- Verify with the cheapest check that proves it works.

## Tools (in the container, run via `sh`)
`rd FILE [s] [e]` read lines · `edit FILE` replace one exact match (stdin: old, `=====`, new) · `wr FILE` write stdin · `put FILE` same as wr · `get PATH` print text, or a download link for binaries and folders · `gl 'GLOB'` find files · `rg` search · `handoff` resume notes (run first; `handoff add "..."` after each milestone, so another account can continue). Success prints `.`. `tools` lists them.
