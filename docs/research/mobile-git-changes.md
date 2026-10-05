# Viewing Host git changes on mobile

Issue: [#220](https://github.com/ZingerLittleBee/Heeler/issues/220).
Date: 2026-09-28

## Status and current implementation

This is the pre-implementation research record, with later measurement notes
retained where they were added. Its proposed method names, implementation plan,
and source-line anchors describe that investigation; they are not the current
acceptance brief or a source map.

Read [the current Changes route](../agents/navigation.md#changes-and-agent-directory)
for the implemented owners and tests. `Agent.foregroundCwd` and
`ConsoleAgent.directory` now carry the current directory. The typed Transport
operations are `readChanges`, `readFilePatch`, and `listUntrackedDirectory`;
`HeelerSSHTransport.runGitScript` owns their bounded exec lifetime. Changes,
untracked-directory expansion, intraline highlighting, Copy/Ask, and wide
side-by-side rendering have implementations in `Sources/Heeler/Changes/`.

Use [testing.md](../agents/testing.md) for current test lanes and fixture entry
points, and [the handoff template](../agents/review-handoff.md) for amended
acceptance and candidate-specific evidence. The historical observations below
retain their recorded versions and verification limits. Protocol observations
formerly in `CLAUDE.md` now live in
[herdr-compatibility.md](../agents/herdr-compatibility.md).

## Decision

It is feasible without changing herdr and without a new SSH or UI dependency.
herdr cannot supply git status, a changed-file list, a diff or file contents
(0.9.0, 0.9.1 and the 2026-09-28 preview alike), so the data must come from
the Host's own `git` CLI over Heeler's existing SSH exec path, parsed and
rendered natively. herdr's part is limited to mapping an Agent to a directory
and signalling when to refresh. Every surveyed product that shows a live remote
worktree's changes works this way: git runs on the Host, text goes to the client.

Recommended v1 is read-only:

1. **Entry.** A "Changes" item in the Agent action menu (Composer More and
   Direct Input More), plus a link from Worktree Details and from the
   `dirty_worktree_requires_force` refusal.
2. **Identity.** Resolve the repository on the Host with
   `git rev-parse --show-toplevel` from the Agent's directory. Never use
   herdr's `repo_root` and never resolve per `workspace_id`.
3. **Data.** One bounded exec per refresh resolves the toplevel and returns
   porcelain v2 status and numstat. A per-file patch is fetched lazily on tap
   and byte-capped on the Host.
4. **Script.** A hardened POSIX script is sent on stdin to the fixed command
   `/bin/sh -s`. It frames every command with nonce markers, takes no index
   locks, and neutralizes repo config that would run programs or change the
   output format. The complete script is in [Script shape](#script-shape) and
   was run live end to end.
5. **Refresh.** On appear, on pull-to-refresh, and when the Agent's status
   leaves Working. No tight polling.
6. **Rendering.** A hand-written parser feeds lazy per-file rows. Unified with
   wrapping is the default on iPhone and iPad. No WebView, no Ghostty surface,
   no syntax-highlighting dependency.
7. **Boundary.** New purpose-built `Transport` requirements with safe defaults.
   No generic exec API and no further `as? HeelerSSHTransport` downcast.

The rest of #220 (stage, unstage, discard, commit) stays out of v1. Those
operations take mandatory index locks under a possibly working Agent and mutate
the user's repository, which deserves its own decision record.

Two things change how #220 should be read. It cannot be built as written: it
presupposes a Files tree and a "Project Root" that exist only on a withdrawn
fork (see [#220 and "ADR 0015"](#220-and-adr-0015)). And a zero-code route
already works today through the Shell Terminal (see
[What works today](#what-works-today)).

## Evidence and provenance

Six dimensions were researched and then adversarially re-verified. Only claims
the verification confirmed, or corrected, appear here. A final review pass
re-ran the complete script in [Script shape](#script-shape). Methods are labelled
**read** (source, spec or documentation read, not run), **live** (run and
observed) or **inference**.

| Component | Version | Method |
| --- | --- | --- |
| herdr schema snapshot | 0.9.0, protocol 22: 102 methods, 26 event kinds, 27 subscription kinds (`scripts/herdr-schema.json`) | read |
| herdr on this Mac | 0.9.1: 103 methods, adds only `pane.link.resolve`; event schemas byte-identical | live, `herdr api schema --json` |
| herdr upstream | v0.9.1 latest stable (2026-09-16, `065ef9d6`); `preview-2026-09-28-80c0c07250d2`; master `267d47fb` (one docs-only commit past `80c0c072`) | live, `gh release list`, `git ls-remote` |
| git | Homebrew 2.55.0; Apple Git 2.54.0 (Apple Git-157) at `/usr/bin/git`; Ubuntu 18.04/20.04/22.04 containers (2.17.1/2.25.1/2.34.1); Alpine 3.21 (BusyBox). The complete script ran on 2.55.0, Apple Git 2.54.0 and 2.34.1 | live |
| git on CI | macos-26-arm64 image lists Git 2.55.0, CLT and Xcode 26.6 ([runner-images](https://github.com/actions/runner-images/blob/0af81b6d930d02b52941d584bee9214c4bc228c6/images/macos/macos-26-arm64-Readme.md)) | doc, not observed inside the fixture |
| libssh2 | `c7557852` (`Packages/HeelerSSH/Sources.lock`) | read |
| libghostty-spm / Ghostty | `7e45d271` / `82938b63` | read |

Live work was confined to scratch repositories, `ssh localhost` (this account's
login shell is fish), Docker containers and read-only herdr CLI calls
(`api schema`, `agent list`, `workspace list`, `worktree list`). Nothing was
sent that mutates a herdr server. No Heeler build or test ran for this note.
Rendering benchmarks ran on an M3 Max under macOS (AppKit TextKit, Node/V8).
They are proxies, not device measurements.

## What herdr provides, and what it does not

**Not provided** (all read, confirmed live against the 0.9.1 export):

- No method, event or subscription returns git status, changed files, a diff
  or file bytes. The git-related surface is `worktree.create/list/open/remove`,
  three `worktree.*` events and the `WorkspaceWorktreeInfo`, `WorktreeInfo` and
  `WorktreeSourceInfo` records. The exported schema is not a full inventory
  (the v0.9.1 [`Method` enum](https://github.com/herdrdev/herdr/blob/v0.9.1/src/api/schema.rs#L47-L269)
  has 104 wire methods), but the one hidden method, `pane.graphics.stream`, is
  not git-related. It is hidden with `#[schemars(skip)]`
  ([schema.rs](https://github.com/herdrdev/herdr/blob/v0.9.1/src/api/schema.rs#L206-L208)),
  which is why CLAUDE.md, reading the 0.8.0 export, records it as absent.
  The preview removes it.
- herdr computes a branch and ahead/behind internally, only for sidebar tokens
  ([status.rs](https://github.com/herdrdev/herdr/blob/v0.9.1/src/workspace/git/status.rs#L100-L199),
  [git_refresh.rs](https://github.com/herdrdev/herdr/blob/v0.9.1/src/app/git_refresh.rs#L95-L112)).
  `WorkspaceInfo` exposes neither. Per-worktree branch names are available
  through `worktree.list`.
- The only dirty check, `checkout_has_dirty_files`, is compiled for Windows and
  tests only and returns a bool
  ([worktree.rs](https://github.com/herdrdev/herdr/blob/v0.9.1/src/worktree.rs#L194-L237)).
  A `worktree.remove` refusal is the only dirty signal on the API, and it is
  destructive, so it is not a probe.
- No file-change event exists. All 26 event kinds are lifecycle events.
- Plugin v1 cannot register methods or push data to clients
  ([plugins.mdx](https://github.com/herdrdev/herdr/blob/v0.9.1/docs/next/website/src/content/docs/plugins.mdx#L31-L33)).
  A plugin action could run `git`, but `plugin.action.invoke` returns
  immediately. Output is capped at 64 KiB per stream, lossy-UTF-8 decoded,
  and readable only by polling `plugin.log.list`, a global ring of 200 records
  ([runtime.rs](https://github.com/herdrdev/herdr/blob/v0.9.1/src/app/api/plugins/runtime.rs#L11-L13)).
  Heeler's own two `pane.agent_status_changed` hooks
  ([herdr-plugin.toml](../../plugin/herdr-plugin.toml#L29-L35)) add records to
  that same ring. This route is strictly worse than exec.
- `pane.read`/`agent.read` return terminal text, and Claude's `agent_session`
  is a UUID, not a transcript path (live).

**Provided, and useful for mapping and triggers:**

- **Agent to directory.** `cwd` is the pane shell's OSC 7-reported directory,
  falling back to the shell process's cwd. `foreground_cwd` is the cwd of the
  foreground process-group leader (the agent CLI). It is Unix-only, and when the
  leader's cwd is unreadable it falls back to another group member
  ([pane.rs](https://github.com/herdrdev/herdr/blob/v0.9.1/src/pane.rs#L3338-L3399)).
  Heeler's `Agent` keeps only `cwd`
  ([Transport.swift:736](../../Sources/Heeler/Transport/Transport.swift#L736)),
  while `ConsoleTerminal.cwd` already uses `foregroundCwd ?? cwd`
  ([ConsoleTerminal.swift:53](../../Sources/Heeler/Console/ConsoleTerminal.swift#L53-L54)).
  On this Mac all three Claude Agents reported `cwd == foreground_cwd` (live).
- **`worktree.list {cwd}`** resolves repo identity, every worktree and its
  branch, and returns `not_git_worktree` outside a repository. It mutates
  nothing (live; [worktrees.rs](https://github.com/herdrdev/herdr/blob/v0.9.1/src/app/api/worktrees.rs#L48-L80)).
  It has four caveats:
  - For a linked worktree, `source.repo_root` is the **parent** checkout
    ([worktrees.rs](https://github.com/herdrdev/herdr/blob/v0.9.1/src/app/api/worktrees.rs#L685-L726)).
    Live, `--cwd .../worktree/Heeler/fix-pr-308-session-switcher` returned
    `repo_root=/Users/zingerbee/Documents/Heeler`, while
    `git rev-parse --show-toplevel` returned the linked checkout. The preview's
    async rewrite keeps this meaning
    ([reads.rs](https://github.com/herdrdev/herdr/blob/80c0c07250d22f69d3fa05cb1700302d66180eb8/src/app/api/worktrees/reads.rs#L299-L339)).
  - `{workspace_id}` yields one identity per Workspace, and Workspaces mix
    repositories. Live, workspace `wY` holds a Claude pane in `amux` and a pane
    in `ServerBee`, and `--workspace wY` returns only `amux`.
  - On 0.9.1 and earlier it runs `git worktree list --porcelain` synchronously
    inside the server's request handler
    ([worktree.rs](https://github.com/herdrdev/herdr/blob/v0.9.1/src/worktree.rs#L494-L514),
    [api.rs](https://github.com/herdrdev/herdr/blob/v0.9.1/src/app/api.rs#L1031)).
    Moving it off that path landed only in the 2026-09-28 preview (upstream
    herdr #4492, commit `dd33ddf2`).
  - Without `trust_repository`, a repository owned by another user fails with
    `worktree_list_failed`. With it, herdr prepends `-c safe.directory=`
    ([worktree.rs](https://github.com/herdrdev/herdr/blob/v0.9.1/src/worktree.rs#L154-L169)).
- **`WorkspaceInfo.worktree`** is present only for members of a herdr worktree
  group, as parent or child
  ([creation.rs](https://github.com/herdrdev/herdr/blob/v0.9.1/src/app/creation.rs#L392-L402)).
  Live, `w0` and `wK` are both the Heeler checkout, and only `wK` carries it. So
  `ConsoleAgent.repositoryCheckout` being absent does not mean "not a repo", and
  it cannot gate the feature.
- **Refresh trigger.** `pane.agent_status_changed` is pane-scoped and already
  subscribed per pane
  ([HostConsoleProjection.swift:996](../../Sources/Heeler/Console/HostConsoleProjection.swift#L994-L997)).
  `ConsoleStore.agentStatusUpdates(for:)` exposes it as a latest-value stream
  "without opening another event channel"
  ([ConsoleStore.swift:415](../../Sources/Heeler/Console/ConsoleStore.swift#L415-L431)).
- **Optional badge.** `pane.report_metadata`/`workspace.report_metadata`
  tokens (16 keys per report, 32 per resource, 80-character values, not
  restored after a restart;
  [socket-api.mdx](https://github.com/herdrdev/herdr/blob/v0.9.1/docs/next/website/src/content/docs/socket-api.mdx#L782-L796))
  could carry a plugin-computed `+12 −3` summary, and Agent rows already render
  `$custom` tokens
  ([AgentRowLayout.swift](../../Sources/Heeler/Console/AgentRowLayout.swift#L1-L5)).
  Whether pane tokens surface in `AgentInfo.tokens` is **unverified**.

v1 therefore does not call `worktree.list`. An exec `rev-parse` gives identity
and an honest not-a-repo result without loading the herdr server.

## Transport path

The pieces exist, but none is wired for this (read):

- `HeelerSSHTransport.runExec` is private, takes an `.ordinarySession` lease,
  passes no stdin and runs under the 15 s `requestTimeout`
  ([HeelerSSHTransport.swift:1975](../../Sources/Heeler/Transport/HeelerSSHTransport.swift#L1951-L1985),
  [SSHTransportSettings.swift:40](../../Sources/Heeler/Transport/SSHTransportSettings.swift#L40)).
  A non-zero exit is not an error at that layer. `runHostCommand` returns
  stdout only.
- The package's `SSHConnection.execute(_:input:timeout:)` already writes stdin
  and then EOF
  ([SSHConnection.swift:185](../../Packages/HeelerSSH/Sources/HeelerSSH/SSHConnection.swift#L185-L208)).
  Package E2E tests exercise it
  ([SessionDriverE2ETests.swift:2159](../../Packages/HeelerSSH/Tests/HeelerSSHTests/SessionDriverE2ETests.swift#L2157-L2160)).
  The only bounded variant, `executeResponseLine`, is line-oriented.
- `Transport` has no generic exec. Precedents: `listSkills`, `readSkillFile`
  and `readFileSlice` are protocol requirements with default implementations
  ([Transport.swift:224](../../Sources/Heeler/Transport/Transport.swift#L224-L238)).
  The directory browser instead downcasts `as? HeelerSSHTransport`
  ([ConsoleStore.swift:326](../../Sources/Heeler/Console/ConsoleStore.swift#L321-L345)),
  and its fallback throws `.sshUnreachable`, which `withTransport` treats as a
  link failure. Do not copy that pattern.

Constraints the git feature must design around:

| Constraint | Evidence | Consequence |
| --- | --- | --- |
| The login shell parses the exec command line | sshd runs it "via the user's shell using its -c option" (`man sshd`); `RemoteShellPath` refuses `'`, `\` and control characters ([Transport.swift:621](../../Sources/Heeler/Transport/Transport.swift#L621-L641)); live: fish mangles `\\` and a trailing `\`, csh/tcsh mangle `!` and newlines | Never put paths on the command line. Send the script on stdin to fixed `/bin/sh -s` and POSIX-quote paths inside it. Live: 25 hostile names round-tripped on sh, dash, bash, zsh, ksh, fish, tcsh, csh and over real sshd with fish |
| A child can eat the rest of a stdin script | live: `cat` mid-script swallowed the remainder on sh, bash, zsh, ksh with exit 0 (dash and BusyBox ash immune) | Wrap the whole script in `{ …; } </dev/null` (parsed fully before execution) |
| Exec output is unbounded | `var stdout = Data()`, appended until EOF ([SessionDriver.swift:3725](../../Packages/HeelerSSH/Sources/HeelerSSH/SessionDriver.swift#L3717-L3870)) | Cap on the Host with `head -c cap+1`. Live: works on macOS, GNU coreutils (Ubuntu) and BusyBox; FreeBSD untested. A 200-commit patch of this repo is 12,940,050 bytes |
| Death by signal reads as exit 0 | `libssh2_channel_get_exit_status` without `has_exit_status` ([SessionDriver.swift:4058](../../Packages/HeelerSSH/Sources/HeelerSSH/SessionDriver.swift#L4058-L4087), [libssh2 channel.c](https://github.com/libssh2/libssh2/blob/c7557852f1b7c0d3b9cffd5390eb33fdf93fb17f/src/channel.c#L1641-L1661)) | Require each command's framed `rc=` line and a final `done` marker ([Script shape](#script-shape)); anything missing means incomplete |
| Login-shell rc output reaches stdout | existing marker framing ([HeelerSSHTransport.swift:2076](../../Sources/Heeler/Transport/HeelerSSHTransport.swift#L2076-L2092), [SkillProbe.swift:68](../../Sources/Heeler/Skills/SkillProbe.swift#L68-L75)) | Parse only after a begin marker. Use a per-request nonce, since repository content can contain any fixed marker (inference) |
| `.timedOut` counts as a link failure | [EventsSession.swift:344](../../Sources/Heeler/Transport/EventsSession.swift#L344-L405): marks the transport suspect, ends events, redials, retries once; the redial bumps `transportGeneration` ([:726](../../Sources/Heeler/Transport/EventsSession.swift#L697-L730)) and `AgentAttachStore` replaces its terminal ([AgentAttachStore.swift:327](../../Sources/Heeler/Console/AgentAttachStore.swift#L327-L344)) | A slow `git status` rebuilds every live terminal on that Host and can cost two 15 s budgets. Bound work by construction and map git overruns to a non-link error |
| Cancel and timeout send no signal | no `libssh2_channel_signal_ex` use in the package | The remote git keeps computing until its next write. Do not stack retries |
| Four ordinary session slots per Host | [SSHChannelAdmission.swift:29](../../Sources/Heeler/Transport/SSHChannelAdmission.swift#L29-L41); shared with SFTP staging, notification files, skills and home probes, and the held session-usage SFTP client; [ADR 0017](../adr/0017-workspace-terminal-inventory-and-retention.md) assumes one-shot commands "rarely overlap" | One git exec in flight per Host. No per-file fan-out and no per-row counts across the Console |
| Non-interactive PATH | macOS sshd default here is `/usr/bin:/bin:/usr/sbin:/sbin` (live); `HerdrHostPath.pathExport` appends extras after `$PATH` ([HerdrHostPath.swift:37](../../Sources/Heeler/Transport/HerdrHostPath.swift#L37-L50)) | Bake in `pathExport`. On macOS `/usr/bin/git` (Apple Git, or the xcode-select shim without CLT) wins unless the login shell puts Homebrew first. Exit 127 means git is missing |
| Non-UTF-8 paths | `String(decoding:as:)` replaces invalid bytes; SFTP paths are `String` | Parse `-z` output as bytes and key files by their raw bytes (inference) |

Cost, live over OpenSSH on localhost with a fresh connection each time:
`ssh true` 0.12 to 0.13 s, porcelain v2 status of this repository 0.18 to 0.19 s.
Heeler's libssh2 exec throughput was measured later (#395) through the weak
network fixture's cellular-like profile (256 KiB/s, 40 ms latency, 15 ms
jitter, 512-byte segments): the exec kept the link full at about 260 KiB/s,
directly and behind the Jump Host alike, so a megabyte takes about four
seconds.

## Git command set

### Locks

- Plain `git status` holds `.git/index.lock` for its whole scan and then
  rewrites the index
  ([commit.c](https://github.com/git/git/blob/v2.55.0/builtin/commit.c#L1634-L1658),
  [git-status BACKGROUND REFRESH](https://github.com/git/git/blob/v2.55.0/Documentation/git-status.adoc#L458-L469)).
  Live on a 30k-file repo, an observer looping status made 125 and 156 of 300
  of an agent's `git add` calls fail in two independent runs.
  `--no-optional-locks` brought it to 0 of 300.
- `git diff` and `git diff HEAD` rewrite the index through auto-refresh even
  under `--no-optional-locks`
  ([diff.c](https://github.com/git/git/blob/v2.55.0/builtin/diff.c#L237-L250)).
  Live: 26 and 29 of 300 failures; `-c diff.autoRefreshIndex=false` gave 0.
  `diff --cached` does not rewrite.
- With auto-refresh off, stat-dirty files show as `M` in `--raw` and
  `--name-status` (false positives), while `--numstat` and `-p` stay correct
  (live). Take the file list from `status` and counts from `--numstat`.
- The price: stat-dirty files are re-hashed on every call. Live with all 30k
  files touched, status took 0.57 to 0.61 s and numstat 1.13 s. Both fell to
  0.059 s after any single index refresh, such as the Agent's own next git
  command. A clean 30k-file status takes 0.053 to 0.060 s.
- `git stash create` is unusable as a baseline, because it takes the index lock
  unconditionally and exits 1 while it is held (live).

### Configuration that runs programs

Each vector was triggered and then neutralized with marker scripts (live,
git 2.55.0). The upstream CVE-2022-24765 notes confirm the class
([RelNotes 2.30.3](https://github.com/git/git/blob/v2.55.0/Documentation/RelNotes/2.30.3.adoc#L13-L20)).

| Vector | Runs during | Neutralizer |
| --- | --- | --- |
| `core.fsmonitor` hook | status, diff | `-c core.fsmonitor=` (**empty**). Never `=false`: git 2.35.1 and older treat it as a hook pathname ([core.adoc](https://github.com/git/git/blob/v2.55.0/Documentation/config/core.adoc#L86-L99)); live on 2.34.1, 2.25.1 and 2.17.1 a `false` on PATH was executed. The empty value ran nothing on all four versions. It also keeps `core.fsmonitor=true` from spawning a long-lived `fsmonitor--daemon` on the Host (observed live by the research on 2.55.0, not re-verified), at the cost of a full scan on huge repositories |
| `post-index-change` hook | any index write | the lock flags above prevent the write; add `-c core.hooksPath=/dev/null` |
| `diff.external`, `diff.<drv>.command`, `GIT_EXTERNAL_DIFF` | diff | `--no-ext-diff` |
| textconv | diff, `log -p` | `--no-textconv` |
| `gpg.program` via `log.showSignature` | every `log`, custom `--format` included | `-c log.showSignature=false` |
| pager | only on a TTY | `--no-pager`, `GIT_PAGER=cat` (exec has no PTY anyway) |
| lazy fetch in partial clones | `log -p`, merge-base, tree diffs (not status or `diff HEAD`) | `GIT_NO_LAZY_FETCH=1` (git 2.45+, ignored by older git; [RelNotes 2.45.0](https://github.com/git/git/blob/v2.55.0/Documentation/RelNotes/2.45.0.adoc#L120-L122)); treat exit 128 as "history not local" |
| clean/process filters (git-lfs) | diff, and status on stat-dirty same-size files | no flag. Codex `/diff` blanks each driver with `clean=`, `process=` and `required=false` ([get_git_diff.rs](https://github.com/openai/codex/blob/c0d26949be4144c751894ae96e28d3db2208b764/codex-rs/tui/src/get_git_diff.rs#L51-L123)). Blanking without `required=false` makes diff fatal (exit 128) for git-lfs, which sets `required=true` ([attribute.go](https://github.com/git-lfs/git-lfs/blob/v3.6.1/lfs/attribute.go#L65-L70)); blanking at all misreports LFS files |

On filters, v1 should honor them (inference). The SSH account is the account
that runs the Agent and its git, so running the user's own filters grants
nothing new, and blanking breaks LFS. Keep Codex-style blanking as an option
for a future cross-user threat model.

A repository owned by another user fails every command with exit 128,
"detected dubious ownership" (simulated live with
`GIT_TEST_ASSUME_DIFFERENT_OWNER=1`;
[setup.c](https://github.com/git/git/blob/v2.55.0/setup.c#L1405-L1435)). Show
that as an error. Never pass `-c safe.directory` automatically, because that
check is the CVE-2022-24765 protection.

### Configuration that changes output

All live on 2.55.0:

- `diff.noprefix`, `diff.mnemonicPrefix` (`i/`, `w/`) and `diff.srcPrefix`:
  pass `--src-prefix=a/ --dst-prefix=b/`. Not `--default-prefix`, which needs
  git 2.41.
- `diff.context=0`: pass `-U3` explicitly.
- `diff.relative=true` in a subdirectory empties the diff:
  `-c diff.relative=false`. `--no-relative` fails before 2.28.
- `color.ui=always`: `--no-color`. `diff.submodule=log`: `--submodule=short`.
  `status.showUntrackedFiles=no`: explicit `-u<mode>`.
- Without `-z`, porcelain v2 paths are C-quoted and, with the default
  `status.relativePaths`, relative to the cwd
  ([wt-status.c](https://github.com/git/git/blob/v2.55.0/wt-status.c#L2398-L2405)).
  Always use `-z` and run from the toplevel.
- `GIT_DIFF_OPTS` overrides even an explicit `-U`
  ([git.adoc](https://github.com/git/git/blob/v2.55.0/Documentation/git.adoc#L639-L643)),
  and a leaked `GIT_DIR` pairs another repository's index with this worktree.
  Unset the repository-local variables (`git rev-parse --local-env-vars`).
- Pathspec magic: `[ab].txt`, `*.txt`, `:!a.txt` and `x?y` each matched other
  files. `--literal-pathspecs` fixed all four, and `dir/` prefixes still work.

### Version floor

Each recommended flag ran live on 2.17.1, 2.25.1, 2.34.1 and 2.55.0. The
complete script below ran on 2.34.1, Apple Git 2.54.0 and 2.55.0; it was not
re-run as a whole on 2.17.1 or 2.25.1. Unknown `-c` keys are ignored by older
git, and `GIT_NO_LAZY_FETCH` is ignored before 2.45. Porcelain v2 arrived in
2.11 and `--no-optional-locks` in 2.15. Avoid:
`status --find-renames` (2.18), `--no-relative` (2.28), `--no-mailmap` (2.27),
`--default-prefix` and `--attr-source` (2.41), and `rev-parse --path-format`
(2.31), which older git echoes to stdout with exit 0 instead of failing. The
`# stash` header line appears only from 2.35.

### Script shape

v1 needs two scripts, each sent as `input:` to the fixed exec command
`/bin/sh -s`: a changes script (discovery, status and counts in one round trip)
and a per-file patch script. `<nonce>` is fresh per request. Every path is
POSIX single-quoted inside the script (`'` becomes `'\''`) and never appears on
the exec command line.

Changes script:

```sh
{
N=__HEELER_GIT_<nonce>__
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_CONFIG \
  GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_PREFIX GIT_IMPLICIT_WORK_TREE \
  GIT_GRAFT_FILE GIT_NO_REPLACE_OBJECTS GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE \
  GIT_NAMESPACE GIT_EXTERNAL_DIFF GIT_DIFF_OPTS GIT_ATTR_SOURCE \
  GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS
LC_ALL=C GIT_PAGER=cat PAGER=cat GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 \
  GIT_NO_LAZY_FETCH=1
export LC_ALL GIT_PAGER PAGER GIT_TERMINAL_PROMPT GIT_OPTIONAL_LOCKS \
  GIT_NO_LAZY_FETCH
<HerdrHostPath.pathExport>
g() { git --no-pager --no-optional-locks --literal-pathspecs \
  -c core.fsmonitor= -c core.hooksPath=/dev/null -c core.quotePath=false \
  -c color.ui=false -c diff.autoRefreshIndex=false -c diff.relative=false \
  -c log.showSignature=false "$@"; }
# sec CAP NAME CMD...: frames one command. stdout carries at most CAP+1 bytes
# of its output between "\n$N NAME begin\n" and "\n$N NAME rc=<status>\n";
# stderr carries its messages between matching begin and end lines.
sec() {
  cap=$1 name=$2; shift 2
  printf '\n%s %s begin\n' "$N" "$name"
  printf '\n%s %s begin\n' "$N" "$name" >&2
  rc=$( { { "$@"; echo "$?" >&4; } | head -c "$((cap + 1))" >&3; } 4>&1 )
  printf '\n%s %s rc=%s\n' "$N" "$name" "$rc"
  printf '\n%s %s end\n' "$N" "$name" >&2
}
# HEAD, or this repository's empty tree (SHA-1 or SHA-256) when HEAD is unborn.
base() {
  g -C "$1" rev-parse -q --verify HEAD 2>/dev/null ||
    g -C "$1" hash-object -t tree /dev/null
}
dir='<agent directory>'
sec 65536 discover g -C "$dir" rev-parse --show-toplevel --show-prefix --absolute-git-dir --git-common-dir
top=$(g -C "$dir" rev-parse --show-toplevel 2>/dev/null)
if [ -n "$top" ]; then
  sec 2097152 status g -C "$top" status --porcelain=v2 -z --branch --show-stash --untracked-files=normal
  b=$(base "$top")
  sec 1048576 numstat g -C "$top" diff "$b" --numstat -z --no-ext-diff --no-textconv --find-renames --submodule=short
fi
printf '\n%s done\n' "$N"
} </dev/null 3>&1
```

The per-file script keeps everything up to and including `base()`, then runs
one of these bodies before the same `done` line and closing brace:

```sh
top='<toplevel from discover>'
b=$(base "$top")
sec 262144 patch g -C "$top" diff "$b" --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ -U3 --find-renames --submodule=short -- '<path>' ['<origPath>']
```

```sh
top='<toplevel from discover>'
sec 262144 patch g -C "$top" diff --no-index --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ -U3 -- /dev/null '<untracked path>'
```

`<HerdrHostPath.pathExport>` expands to `export PATH="$PATH:<extraPATH>"`
([HerdrHostPath.swift:48](../../Sources/Heeler/Transport/HerdrHostPath.swift#L37-L50)).
The whole script is one brace group, so the shell parses it completely before
running anything, and `</dev/null` keeps any child from reading the rest of it.
`3>&1` gives `sec` a handle on the real stdout from inside its command
substitution.

Verification (live, this review pass). A Python stand-in for `GitProbe`
generated these two scripts, with the literal `extraPATH`, and parsed the output
by the rules below. Runs:

- `/bin/sh` (macOS bash 3.2 in sh mode), dash, bash, zsh and ksh, and
  `ssh localhost` with fish as the account shell, all with Homebrew git 2.55.0;
- `/bin/sh` with only `/usr/bin:/bin:/usr/sbin:/sbin` on `PATH`, so Apple Git
  2.54.0 won, which is the CI fixture's situation;
- dash with git 2.34.1 in an Ubuntu 22.04 container, with a fake `false` first
  on `PATH`.

The Apple Git and 2.34.1 runs used larger status and count caps (8 and 4 MiB).
Caps affect none of the checks below.

The repository's config set a `core.fsmonitor` hook, a `post-index-change` hook,
`diff.external` and a textconv driver, each writing a marker file. It also set
`diff.noprefix`, `diff.context=0`, `color.ui=always`, `diff.relative=true` and
`status.showUntrackedFiles=no`, and tracked files were made stat-dirty with
`touch`. Its 19 status entries covered a modification, a staged add, a staged
rename, a binary file, an untracked file, and files named `--`, `-dash.txt`,
`sp ace.txt`, `quo"te.txt`, `sq'uote.txt`, `two\\bs.txt`, `trail\`,
`bang!.txt`, `$HOME.txt`, `*.txt`, `[ab].txt`, `ünï.txt`, and names containing a
newline and a tab.

Results:

- Every run reached `done`, and all 19 per-file patches began with `diff --git`.
- `.git/index` kept its inode and mtime, and no marker file was written.
- A `cat` inserted mid-script did not consume the rest.
- Unborn SHA-1 and SHA-256 repositories produced counts and patches through
  the empty-tree base.
- A non-repository and a missing directory stopped after `discover` with
  exit 128 and the expected `LC_ALL=C` stderr.
- `hash-object -t tree /dev/null` did not run a required `* filter=` clean
  filter in a separate check.

The research had separately round-tripped 15 of 15 diffs with its own
composite.

Parsing rules for `GitProbe`:

- A section is the bytes between `\n<N> <name> begin\n` and the first
  `\n<N> <name> rc=<digits>\n` after it. The leading `\n` of each marker is
  added by `sec`, so a section body needs no further trimming. The nonce keeps
  repository content and stale output from matching.
- A section without its `rc=` line, or output without `\n<N> done\n`, is
  incomplete, whatever the channel's exit status says (signal deaths read as 0).
- More than CAP bytes means truncated. Keep the first CAP bytes and, for `-z`
  output, drop the partial last record. `rc=141` (SIGPIPE; 269 on ksh) appears
  when git was still writing, but a small overrun can end with `rc=0` because
  git finished before `head` exited (live: a 10-byte cap on a 119-byte patch).
  Length is the only reliable truncation signal.
- Classify failures by the section's framed stderr, not by the exit status of
  the whole exec. The research's first wrapper printed each status undelimited
  to stderr, where it ran into git's messages (`0fatal: ambiguous argument`).
  Framing fixes that.
- Treat every body as bytes. Key files by the raw bytes of their `-z` records.

The commands:

1. **Discovery**, once per Agent directory, then cached by toplevel.
   `discover` prints four lines: the toplevel, the prefix (empty at the
   toplevel), the absolute git dir and the common dir. A toplevel containing a
   newline cannot be split by line; treat it as unsupported, as `RemoteShellPath`
   already refuses control characters. Every failure below exits 128, so
   classify it by the `LC_ALL=C` stderr text. Without `LC_ALL=C` the message is
   localized (German was shown live):

   | stderr contains | Meaning | State to show |
   | --- | --- | --- |
   | `not a git repository` | not a repository | honest empty state (#220's own acceptance) |
   | `detected dubious ownership` | owned by another user | explain; do not bypass |
   | `must be run in a work tree` | bare, or inside `.git` | unsupported |
   | `cannot change to` | directory is gone | stale Agent directory |

   Exit 127 means git is missing. `--show-toplevel` is a realpath (`/tmp`
   becomes `/private/tmp`), so relate the Agent directory through
   `--show-prefix`. `--git-common-dir` is relative to the cwd (also on 2.55)
   except in a linked worktree, where it differs from `--absolute-git-dir`.
2. **Status.** NUL-terminated records
   ([git-status.adoc](https://github.com/git/git/blob/v2.55.0/Documentation/git-status.adoc#L294-L360)):
   `# branch.oid|head|upstream|ab`, `1`, `2 … R<score> path\0origPath`, `u`,
   `?`. Object ids are 40 or 64 hex. An unborn branch reports
   `# branch.oid (initial)`, and `branch.ab` is absent when the upstream is
   gone. `--untracked-files=normal` collapses an untracked directory to one
   `dir/` record. Expand it on tap with
   `status --porcelain=v2 -z --untracked-files=all -- '<dir>/'`.
3. **Counts.** Never add `-U`, which implies a full patch. Renames use
   `a\td\t\0old\0new\0` and binary files `-\t-`
   ([diff-format.adoc](https://github.com/git/git/blob/v2.55.0/Documentation/diff-format.adoc#L145-L175)).
   Unmerged paths print two lines. A rename-limit warning on stderr is not a
   failure. `diff HEAD` exits 128 on an unborn HEAD, which is why the script
   diffs against `base`. `diff HEAD` can pair renames differently from status,
   so key the UI on status records.
4. **Per-file patch**, lazily. Pass **both** paths for a rename, or it degrades
   to an add (live). Diffing against HEAD also avoids combined `diff --cc`
   output for conflicts.
5. **Untracked file.** Exit 1 means both "differs" and "Could not access", so
   judge success by the body starting with `diff --git`. A FIFO blocks it
   indefinitely; status never lists FIFOs, so only take paths from status.
   `Transport.readFileSlice` (SFTP range read) is an alternative.

The caps in the script (64 KiB discovery, 2 MiB status, 1 MiB counts,
256 KiB per file, with a "load more" of about 1 MiB) and a limit of about 2,000
displayed files are judgment (inference) informed by the precedents: Happy
Agent 512 KiB, herdr-mobile-relay 1 MiB per diff and 8 MiB for status, GitHub
500 KB per file. A modified-file status record is about 110 bytes plus its
path with SHA-1 ids and about 160 plus its path with SHA-256 ids (live), so
the 2 MiB status cap holds roughly 10,000 to 14,000 records with 40-byte paths
(inference).

Measurement later lowered two of them (#395). Over the cellular-like profile, a
Changes read of 14,001 modified files printed 2.84 MB (a full 2 MiB status plus
0.7 MB of counts) and took 10.4 to 10.5 s in five runs on each route, past the
10 s git deadline. With a 1 MiB status and 512 KiB of counts it printed 1.57 MB
and took 5.5 to 5.6 s; the status still held 6,472 records, and a 1 MiB Load
More patch took 4.0 s. The per-file caps are unchanged.

## Rendering on iPhone and iPad

| Option | Verdict | Why |
| --- | --- | --- |
| SwiftUI `LazyVStack`/`List` rows fed by a hand-written parser | **v1** | no dependency; per-row gutter, background and VoiceOver label; per-file row counts are small |
| TextKit 2 `UITextView` or `UICollectionView` list | later | viewport layout scales; range selection and find; section snapshots give hunk collapse |
| One `Text` per file (the [SkillContentSheet](../../Sources/Heeler/Skills/SkillContentSheet.swift) pattern) | no | lays out the whole document; no gutters or per-row accessibility; selection is whole-Text before iOS 27 |
| Ghostty `InMemoryTerminalSession` fed `git diff --color=always` | spike or fallback only | technically works ([TerminalThemePreview.swift](../../Sources/Heeler/Settings/TerminalThemePreview.swift#L31-L65)). LF must become CRLF, since `ESC[20h` has no effect on the pinned surface's output path ([stream_handler.zig](https://github.com/ghostty-org/ghostty/blob/82938b633ba646db38591d969c3c526332bd7e65/src/termio/stream_handler.zig#L554-L557)). File content passes OSC 52 and `ESC[2J` through verbatim, so everything but SGR must be stripped. Bytes before attach are capped at 1 MiB, oldest dropped. Copy reaches the visible screen only, and there is no per-line VoiceOver, line numbers or navigation. The package's own touch scroll does scroll normal-buffer scrollback |
| `WKWebView` with diff2html 3.4.55 | no | 26 MB (unified) and 48 MB (side-by-side) of HTML for a 3.1 MB diff; keeps the trailing TAB and undecoded C-quoted names; adds a WebContent process and a second design system to an app with no WebKit |
| [tornikegomareli/gitdiff](https://github.com/tornikegomareli/gitdiff/blob/114b571a6dd0660ec9a57ba58a897964020f6bc2/Sources/gitdiff/Core/DiffParser.swift#L19) 0.1.0 (MIT) | reference only | live: doubles CRLF hunk lines, keeps the TAB, leaves quoted paths undecoded, splits headers on spaces, force-unwraps, about 4x slower |

Measurements (live, M3 Max macOS, proxies):

- The prototype parser read a real 3.1 MB diff (289 files, 68,383 lines, 961
  hunks) in about 16 ms.
- TextKit 2 laid out the first screen in 13.7 to 13.9 ms, but the whole
  document at 390 pt in 1.5 to 1.65 s. SwiftUI `Text` measured 397 ms for the
  3.1 MB diff and 36 ms for 101 KB.
- Word-level intraline with the stdlib `difference(from:)` took 61 to 62 ms for
  1,937 line pairs. It is O(n·m)
  ([Apple](https://developer.apple.com/documentation/swift/bidirectionalcollection/difference(from:))):
  one fully different 5,000-token pair took 451 ms. Cap it (about 200 to 300
  characters or 500 tokens per line) and compute off the main actor.
- This repository's v0.1.0..v0.1.11 diff of Sources and Tests (70,658 lines) has
  a per-file median of about 133 lines, p99 about 1,840 to 2,060 and a max of
  about 2,550 (the spread is the header-counting convention). Opening one file
  at a time keeps row counts in the low thousands. Gate larger files from
  numstat (about 5k lines).

Parser requirements (live, git 2.55.0):

- Split on byte `0x0A`. In Swift `"\r\n"` is one `Character`, and a
  Character-based split merged a CRLF file into the next file's header.
- Mutate hunks in place. A copy-out-and-back version took 780 ms.
- C-unquote names even with `core.quotePath=false`, which still quotes `"`,
  `\`, TAB and newline. Strip the trailing TAB git appends to `---`/`+++`
  names containing a space.
- Handle these shapes: binary (no hunks), mode-only and 100% rename (no
  `---`/`+++`), `\ No newline at end of file`, `Subproject commit`, and combined
  `diff --cc` with `@@@`.
- Decode each line lossily. Latin-1 arrives as raw bytes, and UTF-16 files show
  as "Binary files … differ". Take file identity from the `-z` records and
  render from the first `@@`.

Layout:

- SF Mono advances 8.04 pt at 13 pt (39 columns in 320 pt) and 10.51 pt at the
  17 pt Dynamic Type body size (30 columns). 53.2% of real content lines exceed
  39 columns and 65.0% exceed 30. Wrap by default with a hanging indent; offer
  no-wrap horizontal scrolling as an option.
- The largest iPad (13-inch, 1376 pt landscape) shows the sidebar by default
  (ideal 380 pt,
  [ConsoleSplitPresentation.swift:33](../../Sources/Heeler/Console/ConsoleSplitPresentation.swift#L33-L39)),
  leaving about 996 pt for the detail; the 11-inch leaves about 830 pt.
  Side-by-side needs roughly 1,000 to 1,200 pt, so it fits only with the
  sidebar collapsed on the 13-inch. Default to unified on iPad too.
- Regular-width Console sheets use `.presentationSizing(.form)`
  ([ConsoleSheetPresentation.swift:43](../../Sources/Heeler/Console/ConsoleSheetPresentation.swift#L43-L55)),
  which Apple documents as
  [slightly less wide than `.page`](https://developer.apple.com/documentation/swiftui/presentationsizing/form).
  Use `.page` sizing or a detail-column destination for the diff.
- Lazy stacks "trade some degree of layout correctness for performance"
  ([Apple](https://developer.apple.com/documentation/swiftui/creating-performant-scrollable-stacks)),
  so scroll-to-hunk and the scroll indicator can jump. Profile on a device.

Interaction, accessibility and colour:

- With an iOS 18 target ([project.yml](../../project.yml#L4-L5)), SwiftUI
  `textSelection` acts on the whole `Text` before iOS 27
  ([Apple](https://developer.apple.com/documentation/swiftui/view/textselection(_:))).
  Provide Copy Line, Copy Hunk and Copy Path menus. Present the existing
  read-only `UITextView` selection sheet for free selection. It uses a fixed
  14 pt font
  ([TerminalTextSelectionPresenter.swift:50](../../Sources/Heeler/Terminal/TerminalTextSelectionPresenter.swift#L47-L55))
  and would need `UIFontMetrics`.
- Always render the `+`/`−` glyph, since the UI must not rely on colour alone
  ([Apple](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilitydifferentiatewithoutcolor)).
  Give each row a label such as "Added, line 42: …", and add
  `accessibilityRotor` entries for hunks and files. Support Dynamic Type.
- Add a separate `DiffPalette`. `AgentStatusPalette` promises that "a colour
  never means two things"
  ([AgentStatusPalette.swift:4](../../Sources/Heeler/Console/AgentStatusPalette.swift#L4-L7)),
  and status green must not also mean "added". The bundled JetBrains Mono and
  IBM Plex Mono are registered process-wide
  ([TerminalFontSettings.swift:67](../../Sources/Heeler/Settings/TerminalFontSettings.swift#L56-L67)),
  so the diff can reuse the terminal font.

Dependencies: v1 needs none. Syntax highlighting would need maintainer approval
under the "ask before heavyweight dependencies" rule, plus an exact pin,
`Package.resolved`, an `inventory.json` entry and a passing
[LicenseNoticeTests](../../Tests/HeelerTests/LicenseNoticeTests.swift#L121-L172)
check:

- **Highlightr 2.3.0** (MIT): highlight.js 11.11.1, a 1.09 MB script, 192
  languages. In-app JavaScriptCore has no JIT on iOS devices
  ([WebKit ExecutableAllocator.cpp](https://github.com/WebKit/WebKit/blob/f62059d5478ef72d7664a23d03b86cea921c300a/Source/JavaScriptCore/jit/ExecutableAllocator.cpp#L132-L141)),
  so budget at the `--jitless` figure: 89 to 100 ms per 208 KB of Swift on an
  M3 Max, and slower on a phone. The simulator does have JIT, which makes
  simulator timings misleadingly fast.
- **HighlightSwift 1.1.0**: 308 KB, no release since 2024.
- **Splash**: Swift only.
- **tree-sitter-swift**: 3.75 MB linked per grammar, against a 19.1 MB app
  executable.
- **Excluded**: STTextView (GPL-3.0 or commercial; Heeler is Apache-2.0) and
  CodeEditSourceEditor (macOS only).

## Prior art

| Product | Where the data comes from | How it reaches the client | Pattern worth copying or avoiding |
| --- | --- | --- | --- |
| [Happy](https://github.com/slopus/happy/blob/4cf54d18488cba4787cc251cc37010f31125af29/packages/happy-app/sources/sync/gitStatusSync.ts#L135-L172) (legacy sessions) | host git; the app builds the command strings | generic `bash` RPC to a host daemon (Node `exec`, default 1 MiB `maxBuffer`, reproduced live) | closest analog to Heeler's exec. It refreshes on every incoming message, plus 300 ms-debounced tool/agentState triggers. Per-file `diff HEAD` fetched with `Promise.all`; files over 2,000 changed lines auto-collapse; split view on web only |
| [Remodex](https://github.com/Emanuele-web04/remodex/blob/00b29057c35794d7802b3fbc7d9a4d102d34517f/phodex-bridge/src/git-handler.js#L2592-L2630) (SwiftUI, Codex) | host bridge `git/*` RPC, `execFile` with 50 MiB | relay | repo-wide patch fetched on tap, against the empty tree when HEAD is unborn, else the merge-base with `@{u}`, else the parent of the first local-only commit, else HEAD; per-hunk collapse; 350 ms debounce; no git hardening |
| [Codex TUI `/diff`](https://github.com/openai/codex/blob/c0d26949be4144c751894ae96e28d3db2208b764/codex-rs/tui/src/get_git_diff.rs#L18-L24) | host git | local | the only surveyed tool that blanks filter drivers; also `--no-ext-diff --no-textconv`, `core.hooksPath=/dev/null`, an fsmonitor probe, `safe.bareRepository=explicit`. Worktree versus index only, so staged changes are hidden. Output uncapped |
| [Codex desktop, ChatGPT Remote](https://learn.chatgpt.com/docs/code-review?surface=app) | Codex app server on the host (an SSH host needs `codex` installed) | ChatGPT | Unstaged, Staged, Commit, Branch and Last turn scopes; stage, unstage and revert per file and hunk on desktop |
| [herdr-mobile-relay](https://github.com/0cv/herdr-mobile-relay/blob/1560026aa07305f3259a71e2703f6a04f50f8ef6/internal/workspace/inspector.go#L282-L345) | host git in the herdr pane `cwd` | herdr plugin, relay, web app | `--literal-pathspecs`, `fsmonitor=false`, hooks off, `GIT_OPTIONAL_LOCKS=0`, but filters still run (live). 1 MiB per diff, 8 MiB status, 2,000 files, 4 processes, 8 s. Rejects the result if the cwd changed mid-inspection; over budget fails rather than truncating. Read-only |
| [herdr-reviewr](https://github.com/persiyanov/herdr-reviewr/blob/cd618b48dc1f4d2cc092f3f26827ac72fb44773e/README.md#L178-L193) | host git; "last turn" baseline via a temp `GIT_INDEX_FILE`, `add -A`, `write-tree`, persisted at `refs/worktree/reviewr/turn-base` | herdr TUI pane | 2 s status polling misses short turns. Line comments go back as one bracketed paste, never submitted |
| [herdr-sidebar](https://github.com/alexarthurs/herdr-sidebar/blob/8dac9acb70c0f4de561d00c04133032e2fd76084/plugins/herdr-sidebar/src/viewer.rs#L1347-L1380) (#220's inspiration) | host git | herdr TUI pane | picks the repo from a sibling pane's `foreground_cwd`; `GIT_OPTIONAL_LOCKS=0` reads; per-file `diff --no-ext-diff [--cached] -- <rel>` plus `--no-index /dev/null` for untracked; stage, discard, commit |
| [Claude Code web and Remote Control](https://code.claude.com/docs/en/remote-control) | cloud VM (raw blobs, so repo diff drivers and textconv do not apply) or the local session | Anthropic cloud | `+42 -18` pill, then file list, then per-file diff. Remote Control shows changes since the branch split when ahead of the default branch, otherwise uncommitted changes. Line comments ride the next message |
| [opencode](https://github.com/anomalyco/opencode/blob/3c893f0a166cfc433819b4eff65d2e6c7696a1c9/packages/opencode/src/snapshot/index.ts#L65-L75) | shadow git dir outside the project | local | per-step diffs that never touch the user's `.git` |
| [Omnara](https://github.com/omnara-ai/omnara/blob/fa808622ed5eead79cfdb4eb6411bff4e76ab722/src/integrations/utils/git_utils.py#L44-L110) (legacy) | host git against HEAD at session start | cloud DB, pushed per message | session-scoped baseline |
| [VibeTunnel](https://github.com/amantus-ai/vibetunnel/blob/f78324f5a6f5617711581cf5b119651094b2d9bc/web/src/server/routes/filesystem.ts#L455-L499) | host `git diff HEAD -- <path>` | host server | iOS `WKWebView` with CDN highlight.js; web Monaco switches to inline below 768 px |
| [Cursor iOS](https://cursor.com/docs/cloud-agent/mobile), GitHub Mobile | hosting API or cloud VM | cloud | PR review, not a live worktree |
| [Working Copy](https://workingcopy.app/manual.html) | on-device git client | local | hunk staging by long-tap and swipe; split view only when wide or in landscape |

Takeaways. Every live-worktree product runs the git CLI on the Host. Read-only
is the norm for agent consoles; writes appear in the Codex desktop app, Working
Copy, herdr-sidebar and Remodex. Budgets and a "too large" state are standard
(GitHub: 20,000 lines or 500 KB per file,
[repository limits](https://docs.github.com/en/repositories/creating-and-managing-repositories/repository-limits);
GitLab collapses at 10% of its limits,
[diff limits](https://docs.gitlab.com/administration/diff_limits/)). Hardening
is inconsistent: only Codex blanks filters, herdr-mobile-relay disables
fsmonitor and hooks, and herdr-sidebar, herdr-reviewr and Remodex do neither.
The "which diff" choice matters: a worktree-versus-index view hides everything
an Agent has already `git add`ed (live: 0 bytes against 124 bytes for
`diff HEAD`).

## Product fit

### #220 and "ADR 0015"

Resolved (live, `gh` and `git`). #219, #220, #221 and #222 were filed by
kruttan on 2026-08-20 between 13:32:27Z and 13:32:31Z. None has a label or
milestone, and the maintainer never replied. A triage note on #219 (aliefe04,
2026-09-09) paused all four because they cite a stale ADR 0015 and an unbuilt
Files surface.

They are the follow-up specs of PR #224 (`kruttan:ipad-files`, +28,007/−114
across 169 files, stacked on #213). It was opened at 13:41Z and closed unmerged
at 14:09Z by its author: "this direction continues on my fork instead".

Their "iPadOS Files evolution (ADR 0015)" is
[`docs/adr/0015-project-files-over-sftp.md` on the fork](https://github.com/kruttan/Heeler/blob/a1b9546e5d34f38e8c54da4febf1364043ab0e06/docs/adr/0015-project-files-over-sftp.md).
That ADR, dated 2026-08-20, puts file operations on app-owned SFTP behind
`Transport`, takes the root from the checkout path or launch cwd, and uses a
`UITextView` editor. When the issues were filed, upstream `main` ended at
ADR 0014. Upstream's own
[ADR 0015](../adr/0015-shell-terminal-via-direct-terminal-attach.md) (Shell
Terminal) landed on 2026-08-24 in `a4a32d0a`. No ref ever renamed an ADR, so
this is a numbering collision, not a renumbering.

Nothing it assumes exists upstream. No Files tree, Project Root, editor or
source-control code exists in any local ref, and `Sources/Heeler/Files` holds
only `FilePreparer.swift`. The fork has Files code but no source-control code
(its `main` is 17 ahead and 895 behind upstream, last pushed 2026-08-21).
[CONTEXT.md](../../CONTEXT.md#L80-L84) lists "project" under _Avoid_ for
Workspace. #220 should be re-scoped as "read-only git status and per-file diff
for an Agent's repository", anchored on Agent or Worktree. This note did not
comment on any issue.

### Where it lives

- **Agent action menu.** Add an optional item next to Skills and Worktree
  Details
  ([AgentActionMenuContent.swift:99](../../Sources/Heeler/Console/AgentActionMenuContent.swift#L95-L112),
  [AgentTerminalView.swift:919](../../Sources/Heeler/Console/AgentTerminalView.swift#L915-L926)).
  Gate it on a non-empty Agent directory, not on `repositoryCheckout`, and let
  discovery produce the empty state.
- **Presentation.** A sheet on iPhone. On iPad, a `.page` sheet or a
  detail-column destination, as the Shell Terminal replaces Agent detail in
  place ([AgentDetailView.swift:207](../../Sources/Heeler/Console/AgentDetailView.swift#L207-L220)).
- **Worktree Details and removal.** The `dirty_worktree_requires_force` refusal
  tells users to "Commit or discard those changes on the Host"
  ([WorktreeRemoval.swift:142](../../Sources/Heeler/Console/WorktreeRemoval.swift#L140-L143)),
  yet the app cannot show those files and offers no force option. A "Show
  changes" link there fits naturally.

### Identity

Directory rules already differ:

- Open Terminal takes the Agent's `cwd` first, then a linked checkout
  ([ShellTerminalStore.swift:7](../../Sources/Heeler/Console/ShellTerminalStore.swift#L7-L26)).
- Skills takes the checkout first, then `cwd`
  ([ConsoleAgent.swift:117](../../Sources/Heeler/Console/ConsoleAgent.swift#L117-L124)).
- `ConsoleTerminal` prefers `foregroundCwd` and also covers Agent panes. A
  surface keyed on `ConsoleTerminal` needs no model change; one keyed on
  `Agent` must first carry `foreground_cwd`
  ([Transport.swift:736](../../Sources/Heeler/Transport/Transport.swift#L736)).

The app calls herdr's `cwd` the launch directory. It is really the pane shell's
current directory, which equals the launch directory while the Agent blocks the
shell.

Recommendation: take the Agent's directory (`foreground_cwd ?? cwd` once
plumbed into `Agent`, otherwise `Agent.cwd`), falling back to
`repositoryCheckout.checkoutPath`. Resolve the toplevel with `rev-parse` on the
Host, and cache per Host, connection generation and toplevel, as
`SkillsCacheKey` does with its root
([ConsoleStore.swift:346](../../Sources/Heeler/Console/ConsoleStore.swift#L346-L351)).
Never use `repo_root` or `workspace_id`.

### Refresh

- Load on appear and on pull-to-refresh, and again when `AgentStatusUpdate`
  leaves Working (done, idle, blocked). Debounce about 300 ms (Happy uses
  300 ms, Remodex 350 ms). A trigger that arrives while a refresh is in flight
  schedules one follow-up rather than a second exec.
- The trigger rides the existing snapshot-derived per-pane subscription, so it
  inherits CLAUDE.md's rules for pane-scoped subscriptions (all-or-nothing
  `events.subscribe`, dropped on reconnect). The feature adds no subscription.
- While the Agent is Working, label the snapshot as possibly incomplete and
  show its time. Poll slowly at most, and only while visible (≥5 s, the
  session-usage precedent at
  [AgentTerminalView.swift:369](../../Sources/Heeler/Console/AgentTerminalView.swift#L369-L393)),
  or not at all. Every read re-hashes stat-dirty files and runs clean filters.
- Never react to `pane.updated`, which fires on every title change.

### What works today

With no new code, More → Open Terminal (or the Workspace drawer or the
Terminals tab) gives a Shell Terminal with direct keyboard input, the Keys pad
and 4 to 32 pt zoom. Open Terminal prefers an existing shell pane in the
Agent's Workspace, whose directory may differ from the Agent's. Only a newly
created tab is guaranteed to start in the Agent's directory.

- `git diff` through its default pager (`less` with `LESS=FRX`) sets only
  application cursor keys (`1h`, live on a bare pty). Heeler turns touch
  scrolling into cursor keys on the alternate screen, so it scrolls.
- lazygit 0.65.1 and hunk 0.22.0 set `1049h` plus mouse modes
  `1000/1002/1003/1006` (live), so Heeler sends SGR wheel reports and taps as
  clicks. The Shell Terminal enables local input.

These mode captures came from a bare pty. The composed path through
`herdr terminal attach` inside Heeler is inference from the 0.8.2 attach
behaviour recorded in CLAUDE.md.

Limits:

- Output printed straight to the prompt (a long `git status`, `git diff | cat`)
  cannot be scrolled back, because touch scrolling becomes shell history keys.
- lazygit switches to portrait layout at ≤84 columns and ≥46 rows
  ([window_arrangement_helper.go](https://github.com/jesseduffield/lazygit/blob/v0.65.1/pkg/gui/controllers/helpers/window_arrangement_helper.go#L120-L132)).
- `hunk diff --watch` reloads as the Agent edits.
- Every tool must be installed on the Host.
- The herdr-sidebar source-control pane and herdr-reviewr open as ordinary
  split panes, so Heeler would list them as Workspace Terminals. That path is
  untested.

### Conventions

- Add a CONTEXT.md term (for example **Changes**, avoiding "project") and a
  CHANGELOG `[Unreleased]` entry. Read-only viewing needs no ADR; writes do.
- New Swift files need the regenerated project committed.

### Test strategy

- **`GitProbe` unit tests.** Assert on the generated script:
  - the exec command is exactly `/bin/sh -s`, and no path appears outside
    single quotes;
  - every hostile name from [Script shape](#script-shape) quotes correctly;
  - `core.fsmonitor=` is empty and `diff.autoRefreshIndex=false` is present.

  Parse recorded output from real runs. Cover the cases in Phase 1 step 2, plus:
  - a section missing its `rc=` line, and output missing `done`;
  - a truncated `-z` body (drop the partial record), and `rc=0` with length
    over the cap;
  - a marker carrying another nonce;
  - login-shell noise on both stdout and stderr.
- **Transport unit test.** A git overrun must surface as a non-link error, so
  `EventsSession.withTransport` neither redials nor retries. Use the existing
  `ScriptedTransport` or `FakeTransportConnector` doubles
  (`Tests/HeelerTests/Support`).
- **Fixture E2E.** The CI fixture execs `/bin/sh -c "$SSH_ORIGINAL_COMMAND"`,
  so `/bin/sh -s` keeps its stdin, and `/usr/bin` on its `PATH` means Apple Git
  (the combination verified above;
  [run-ci-ios-tests.sh:1383](../../scripts/run-ci-ios-tests.sh#L1372-L1385)).
  Test steps:
  1. Seed a repository over exec, as the notification tests seed directories
     ([HeelerSSHTransportBehaviorE2ETests.swift:201](../../Tests/HeelerTests/HeelerSSHTransportBehaviorE2ETests.swift#L199-L202)).
     The fixture has no gitconfig, so commits need `-c user.name`/`-c user.email`.
  2. Install a `core.fsmonitor` hook and a `post-index-change` hook that each
     write a marker file.
  3. Make tracked files stat-dirty with `touch`.
  4. Call the new `Transport` methods.

  Assert that entries parse, that no marker exists, and that
  `stat -f '%i %m' .git/index` (BSD `stat` on the macOS runner) is unchanged.
  This guards the lock and program-execution rules against regression. Bump the
  pinned `run_suite SharedFixtureE2ETests 104 6 0`
  ([run-ci-ios-tests.sh:1979](../../scripts/run-ci-ios-tests.sh#L1979)), or add
  a `run_suite` line for a new suite.
- **Commands.** Run a suite with
  `make test-app TEST_FLAGS='-only-testing:HeelerTests/<Suite>'`, and check that
  the executed count is non-zero and belongs to that suite. `make test` runs
  everything. HeelerSSH needs no change, so
  `scripts/run-heelerssh-package-tests.sh` is not involved.
- **Gaps CI cannot cover.** CI never runs fish, nushell or csh, and never runs
  Linux git. Shell coverage rests on the unit tests and the stdin design, plus
  `scripts/verify-changes-linux-host.sh`, which reads a seeded Checkout on a
  Debian container (git 2.39.5) as a fish and as a POSIX sh login account.
  Rendering cost needs the on-device Instruments spike in Phase 1.

## Risks

- **Link-failure coupling.** A git exec that overruns 15 s through
  `withTransport` redials the Host and rebuilds every live terminal on it
  (read).
- **Lock collisions.** A single missing flag (`--no-optional-locks`,
  `diff.autoRefreshIndex=false`) makes a working Agent's git fail on
  `index.lock` (live).
- **Program execution.** `core.fsmonitor=false`, the obvious spelling, executes
  a binary named `false` on git 2.35.1 and older (live). Clean filters run on
  every read of stat-dirty files.
- **Exec contention.** The four ordinary session slots are shared with staging,
  notification files and probes. Polling or per-row counts would starve them.
- **Size.** Output is buffered unbounded in the app. Whole-repo patches reach
  megabytes (580,549 bytes across 134 files for a single release of this repo).
- **Wrong repository.** Using `repo_root`, `workspace_id` or
  `WorkspaceInfo.worktree` shows the parent checkout, another repository, or
  nothing.
- **Host variance.** Git may be missing from the non-interactive PATH, Apple's
  `/usr/bin/git` shim may lack CLT, git may predate 2.17, `head -c` may be
  absent (FreeBSD untested), and a repository may belong to another user.
- **Staleness.** herdr emits no file-change events, so a view refreshed on
  status edges lags a Working Agent.
- **Unmeasured costs.** Device rendering is unmeasured, and all rendering
  numbers are desktop proxies.
- **Scope drift.** Building #220 verbatim reintroduces the withdrawn fork's
  Files direction.

## Open questions

- **Product scope.** Read-only first, or all of #220? Per Agent or per
  Workspace? Should the view follow an Agent's later `cd` (`foreground_cwd`)?
  Side-by-side on iPad in v1? A dedicated conflict renderer, or a conflict
  badge over the `diff HEAD` view?
- **Dependencies.** Is any syntax-highlighting dependency acceptable?
- **Last-turn scope.** May Heeler write to the Host repository? The temp-index
  baseline leaves loose objects that `git gc` prunes after two weeks; a ref
  keeps them visibly. Or should it use a shadow git dir outside the project?
- **Not measured:**
  - `LazyVStack` with 2,000 to 5,000 wrapped rows on the oldest iOS 18 iPhone;
  - status beyond 30k tracked files, where monorepos rely on fsmonitor;
  - `head -c` on FreeBSD;
  - the complete script on git 2.17.1 or 2.25.1, or on Alpine/BusyBox. The
    individual flags ran on the older git versions, and BusyBox `head -c` and
    ash were tested, but the whole script did not run there. It has since run
    against Debian git 2.39.5 over SSH (#395);
  - split-index or sparse-index repositories with a temp index;
  - real cross-user ownership (only simulated);
  - `foreground_cwd` across Agent kinds on Linux;
  - git inside the CI fixture session.
- **herdr's next release.** How the next stable release reshapes
  `worktree.list`. The preview keeps the parent-checkout meaning.

## Phased plan

**Phase 0, now.** Point users at the Shell Terminal route (`git diff`,
`lazygit`, `hunk diff --watch`) and re-scope #220.

**Phase 1, read-only v1.**

1. Let the private exec helper forward `input:`. HeelerSSH needs no change.
2. Add a pure `GitProbe` enum that builds the scripts in
   [Script shape](#script-shape) and parses output as bytes. Unit-test it on
   recorded samples: CJK, renames, `'`, `\`, glob characters, `--`, `-dash`,
   newline and tab names, binary, untracked, submodule, conflict, unborn,
   SHA-256, login-shell noise, a missing end marker, and truncation (see
   [Test strategy](#test-strategy)).
3. Add `Transport` requirements such as `repositoryChanges(_:)` and
   `repositoryFileDiff(_:)`, with defaults that report "unavailable". Implement
   them in `HeelerSSHTransport` with one git exec per Host in flight. Give them
   a deadline shorter than the 15 s request budget (for example 10 s;
   inference), and map an overrun to an error that
   `EventsSession.isTransportLinkFailure` does not treat as a link failure. The
   remote git keeps running after a cancel, so do not retry automatically.
4. Build the diff parser, `DiffDocument`, lazy per-file rows, `DiffPalette`,
   accessibility and copy.
5. Add the entry points, refresh policy, and states for not a repository, git
   missing, dubious ownership, directory gone, too large and truncated.
6. Add the fixture E2E from [Test strategy](#test-strategy) with its
   pinned-count bump, and the CONTEXT.md and CHANGELOG entries.
7. Run a one-day on-device Instruments spike before committing to SwiftUI rows.

**Phase 2, read-only depth.**

- Staged and unstaged split views.
- A branch scope via `symbolic-ref refs/remotes/origin/HEAD` and `merge-base`
  (Remote Control's rule), with a fallback to `@{upstream}` or local
  `main`/`master`.
- Untracked-directory expansion, intraline highlighting and full context.
- Side-by-side on iPad when the detail is wide enough.
- Image before and after, and `log -z` history.
- An optional plugin-published `$changes` token (unverified surfacing).

**Phase 3, writes (the rest of #220).** Write an ADR first. `add`, `restore`,
`commit` and `reset` accept `--pathspec-from-file`; `diff` does not. These
commands take the index lock unconditionally (inference), so disable them
while the Agent is Working. Confirm discard, and offer file-level and then hunk-level
granularity as the Codex desktop app does.

**Phase 4, optional.**

- **Last-turn scope.** Build it from a temp-index `write-tree` baseline taken
  on the `pane.agent_status_changed` edge. That took 0.12 s on 30k files, left
  the real index and refs untouched and wrote loose objects (live), or use a
  shadow git dir.
- **Line comments to the Agent.** Send them through `pane.send_input` without
  `keys`, which inserts text without submitting (CLAUDE.md, verified on 0.8.0).
